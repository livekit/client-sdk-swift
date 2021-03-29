//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/4/20.
//

import Foundation
import WebRTC
import Promises

class RTCEngine {
    var publisher: PeerConnectionTransport
    var subscriber: PeerConnectionTransport
    var publisherDelegate: PublisherTransportDelegate
    var subscriberDelegate: SubscriberTransportDelegate
    var client: RTCClient
    
    var joinResponse: Livekit_JoinResponse?
    var rtcConnected: Bool = false
    var iceConnected: Bool = false {
        didSet {
            if oldValue == iceConnected {
                return
            }
            if iceConnected {
                guard let resp = joinResponse else {
                    return
                }
                delegate?.didJoin(response: resp)
                self.joinResponse = nil
            } else {
                delegate?.didDisconnect(reason: "Peer connection disconnected")
            }
        }
    }
    
    var pendingCandidates: [RTCIceCandidate] = []
    
    private var audioSession = RTCAudioSession.sharedInstance()
    private var pendingTrackResolvers: [String: Promise<Livekit_TrackInfo>] = [:]
    
    static var offerConstraints = RTCMediaConstraints(mandatoryConstraints: [
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
        kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse
    ], optionalConstraints: nil)

    static var mediaConstraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                                       optionalConstraints: nil)

    static var connConstraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                                      optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
    
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        var encoderFactory = RTCDefaultVideoEncoderFactory()
        var decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()
    
    private static let privateDataChannelLabel = "_private"
    var privateDataChannel: RTCDataChannel?
    
    weak var delegate: RTCEngineDelegate?
    
    init(client: RTCClient) {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: RTCClient.defaultIceServers)]
        // Unified plan is more superior than planB
        config.sdpSemantics = .unifiedPlan
        // gatherContinually will let WebRTC to listen to any network changes and send any new candidates to the other client
        config.continualGatheringPolicy = .gatherContinually
        
        publisherDelegate = PublisherTransportDelegate()
        publisher = PeerConnectionTransport(config: config, delegate: publisherDelegate)
        
        subscriberDelegate = SubscriberTransportDelegate()
        subscriber = PeerConnectionTransport(config: config, delegate: subscriberDelegate)
        
        self.client = client
        publisherDelegate.engine = self
        subscriberDelegate.engine = self
        client.delegate = self
        
        /* always have a blank data channel, to ensure there isn't an empty ice-ufrag */
        privateDataChannel = publisher.peerConnection.dataChannel(forLabel: RTCEngine.privateDataChannelLabel,
                                                                  configuration: RTCDataChannelConfiguration())

        configureAudio()
    }
    
    func configureAudio() {
        audioSession.lockForConfiguration()
        do {
            try audioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue, with: .mixWithOthers)
            try audioSession.setMode(AVAudioSession.Mode.voiceChat.rawValue)
        } catch {
            print("engine error --- configuring audio session: \(error)")
        }
        audioSession.unlockForConfiguration()
    }
    
    func join(options: ConnectOptions) {
        client.join(options: options)
    }
    
    func addTrack(cid: String, name: String, kind: Livekit_TrackType) throws -> Promise<Livekit_TrackInfo> {
        if pendingTrackResolvers[cid] != nil {
            throw TrackError.duplicateTrack("Track with the same ID (\(cid)) has already been published!")
        }
        
        let promise = Promise<Livekit_TrackInfo>.pending()
        pendingTrackResolvers[cid] = promise
        try self.client.sendAddTrack(cid: cid, name: name, type: kind)
        return promise
    }
    
    func updateMuteStatus(trackSid: String, muted: Bool) {
        self.client.sendMuteTrack(trackSid: trackSid, muted: muted)
    }
    
    func close() {
        publisher.close()
        subscriber.close()
        client.close()
    }
    
    func negotiate() {
        print("engine --- starting to negotiate: \(String(describing: publisher.peerConnection.signalingState))")
        publisher.peerConnection.offer(for: RTCEngine.offerConstraints, completionHandler: { (offer, error) in
            guard error == nil else {
                print("engine error --- creating offer: \(error!)")
                return
            }
            guard let sdp = offer else {
                print("engine error --- offer is unexpectedly missing during negotiation!")
                return
            }
            self.publisher.peerConnection.setLocalDescription(sdp, completionHandler: { error in
                guard error == nil else {
                    print("engine error --- setting local desc for offer: \(error!)")
                    return
                }
                self.client.sendOffer(offer: sdp)
            })
        })
    }
    
    private func onRTCConnected() {
        print("engine --- RTC connected")
        rtcConnected = true
        pendingCandidates.forEach { (candidate) in
            client.sendCandidate(candidate: candidate, target: .publisher)
        }
        pendingCandidates.removeAll()
    }
}

extension RTCEngine: RTCClientDelegate {
    func onActiveSpeakersChanged(speakers: [Livekit_SpeakerInfo]) {
        delegate?.didUpdateSpeakers(speakers: speakers)
    }
    
    func onJoin(info: Livekit_JoinResponse) {
        joinResponse = info
        
        // create publisher and subscribers
        
        publisher.peerConnection.offer(for: RTCEngine.offerConstraints, completionHandler: { (sdp, error) in
            guard error == nil else {
                print("engine --- error creating offer: \(error!)")
                return
            }
            guard let desc = sdp else {
                print("engine error --- unexpectedly missing empty session from publisher offer")
                return
            }
            self.publisher.peerConnection.setLocalDescription(desc, completionHandler: { error in
                guard error == nil else {
                    print("engine --- error setting local description: \(error!)")
                    return
                }
                self.client.sendOffer(offer: desc)
            })
        })
    }
    
    func onAnswer(sessionDescription: RTCSessionDescription) {
        print("engine --- received server answer", sessionDescription.type, String(describing: publisher.peerConnection.signalingState))
        publisher.setRemoteDescription(sessionDescription) { error in
            guard error == nil else {
                print("engine error --- setting remote description for answer: \(error!)")
                return
            }
            if !self.rtcConnected {
                self.onRTCConnected()
            }
        }
    }
    
    func onTrickle(candidate: RTCIceCandidate, target: Livekit_SignalTarget) {
        print("engine --- received ICE candidate from peer", candidate, target)
        if target == .publisher {
            publisher.addIceCandidate(candidate: candidate)
        } else {
            subscriber.addIceCandidate(candidate: candidate)
        }
    }
    
    func onOffer(sessionDescription: RTCSessionDescription) {
        print("engine --- received server offer",
              sessionDescription.type,
              String(describing: subscriber.peerConnection.signalingState))
        
        subscriber.setRemoteDescription(sessionDescription, completionHandler: { error in
            guard error == nil else {
                print("engine error --- setting remote description for offer: \(error!)")
                return
            }
            self.subscriber.peerConnection.answer(for: RTCEngine.offerConstraints, completionHandler: { (answer, error) in
                guard error == nil else {
                    print("engine error --- creating answer: \(error!)")
                    return
                }
                guard let ans = answer else {
                    print("engine error --- unexpectedly missing answer from offer")
                    return
                }
                self.subscriber.peerConnection.setLocalDescription(ans, completionHandler: { error in
                    guard error == nil else {
                        print("engine error --- setting local description for answer: \(error!)")
                        return
                    }
                    self.client.sendAnswer(answer: ans)
                })
            })
        })
    }
    
    func onParticipantUpdate(updates: [Livekit_ParticipantInfo]) {
        print("engine --- received participant update")
        delegate?.didUpdateParticipants(updates: updates)
    }
    
    func onLocalTrackPublished(trackPublished res: Livekit_TrackPublishedResponse) {
        print("engine --- local track published: ", res.cid)
        guard let promise = pendingTrackResolvers.removeValue(forKey: res.cid) else {
            print("engine --- missing track resolver for: \(res.cid)")
            return
        }
        promise.fulfill(res.track)
        delegate?.didPublishLocalTrack(cid: res.cid, track: res.track)
    }
    
    func onClose(reason: String, code: UInt16) {
        print("engine --- received close event: \(reason) code: \(code)")
        delegate?.didDisconnect(reason: reason)
    }
    
    func onError(error: Error) {
        print("engine --- client error: \(error)")
        delegate?.didFailToConnect(error: error)
    }
}
