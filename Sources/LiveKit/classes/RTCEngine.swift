//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/4/20.
//

import Foundation
import WebRTC
import Promises

class RTCEngine: NSObject {
    var peerConnection: RTCPeerConnection?
    
    private var client: RTCClient
    private var audioSession = RTCAudioSession.sharedInstance()
    private var rtcConnected: Bool = false
    private var iceConnected: Bool = false
    
    private var pendingCandidates: [RTCIceCandidate] = []
    private var pendingTrackResolvers: [Track.Cid: Promise<Livekit_TrackInfo>] = [:]
    
    static var offerConstraints = RTCMediaConstraints(mandatoryConstraints: [
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
        kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
    ], optionalConstraints: nil)
    
    static var mediaConstraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                                       optionalConstraints: nil)
    
    static var connConstraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                                      optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
    
    
    weak var delegate: RTCEngineDelegate?
    
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL() 
        var encoderFactory = RTCDefaultVideoEncoderFactory()
        var decoderFactory = RTCDefaultVideoDecoderFactory()
        /*
            if TARGET_OS_SIMULATOR != 0 {
                encoderFactory = RTCSimulatorVideoEncoderFactory()
                decoderFactory = RTCSimulatorVideoDecoderFactory()
            }
        */
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()
    
    private static let privateDataChannelLabel = "_private"
    
    init(client: RTCClient) {
        self.client = client
        super.init()
        client.delegate = self
        
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: RTCClient.defaultIceServers)]
        // Unified plan is more superior than planB
        config.sdpSemantics = .unifiedPlan
        // gatherContinually will let WebRTC to listen to any network changes and send any new candidates to the other client
        config.continualGatheringPolicy = .gatherContinually
        
        peerConnection = RTCEngine.factory.peerConnection(with: config, constraints: RTCEngine.connConstraints, delegate: self)
        /* always have a blank data channel, to ensure there isn't an empty ice-ufrag */
        peerConnection?.dataChannel(forLabel: RTCEngine.privateDataChannelLabel, configuration: RTCDataChannelConfiguration())

        configureAudio()
    }
    
    func configureAudio() {
        audioSession.lockForConfiguration()
        do {
            try audioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue, with: .mixWithOthers)
            try audioSession.setMode(AVAudioSession.Mode.voiceChat.rawValue)
        } catch {
            print("engine --- Error occurred configuring audio session: \(error)")
        }
        audioSession.unlockForConfiguration()
    }
    
    func join(roomId: String, options: ConnectOptions) {
        let _ = client.join(roomId: roomId, options: options)
    }
    
    func createOffer() -> Promise<RTCSessionDescription> {
        let promise = Promise<RTCSessionDescription>.pending()
        peerConnection?.offer(for: RTCEngine.offerConstraints, completionHandler: { (sdp, error) in
            guard error == nil else {
                print("engine --- error creating offer: \(error!)")
                promise.reject(error!)
                return
            }
            promise.fulfill(sdp!)
        })
        return promise
    }
    
    func addTrack(cid: Track.Cid, name: String, kind: Livekit_TrackType) throws -> Promise<Livekit_TrackInfo> {
        try self.client.sendAddTrack(cid: cid, name: name, type: kind)
        let promise = Promise<Livekit_TrackInfo>.pending()
        pendingTrackResolvers[cid] = promise
        return promise
    }
    
    func updateMuteStatus(trackSid: String, muted: Bool) {
        self.client.sendMuteTrack(trackSid: trackSid, muted: muted)
    }
    
    private func requestNegotiation() {
        print("engine --- requesting negotiation...")
        client.sendNegotiate()
    }
    
    private func negotiate() {
        print("engine --- starting to negotiate: \(String(describing: peerConnection?.signalingState))")
        peerConnection?.offer(for: RTCEngine.offerConstraints, completionHandler: { (offer, error) in
            guard error == nil else {
                print("engine --- error creating offer: \(error!)")
                return
            }
            self.peerConnection?.setLocalDescription(offer!, completionHandler: { error in
                guard error == nil else {
                    print("engine --- error setting local desc for offer: \(error!)")
                    return
                }
                self.client.sendOffer(offer: offer!)
            })
        })
    }
    
    private func onRTCConnected() {
        print("engine --- RTC connected")
        rtcConnected = true
        pendingCandidates.forEach { (candidate) in
            client.sendCandidate(candidate: candidate)
        }
        pendingCandidates.removeAll()
    }
    
    private func onICEConnected() {
        print("engine --- ICE connected")
        iceConnected = true
    }
}

extension RTCEngine: RTCClientDelegate {
    func onJoin(info: Livekit_JoinResponse) {
        peerConnection?.offer(for: RTCEngine.offerConstraints, completionHandler: { (sdp, error) in
            guard error == nil else {
                print("engine --- error creating offer: \(error!)")
                return
            }
            self.peerConnection?.setLocalDescription(sdp!, completionHandler: { error in
                guard error == nil else {
                    print("engine --- error setting local description: \(error!)")
                    return
                }
                self.client.sendOffer(offer: sdp!)
                self.delegate?.didJoin(response: info)
            })
        })
    }
    
    func onAnswer(sessionDescription: RTCSessionDescription) {
        peerConnection?.setRemoteDescription(sessionDescription) { error in
            guard error == nil else {
                print("engine --- error setting remote description for answer: \(error!)")
                return
            }
            if !self.rtcConnected {
                self.onRTCConnected()
            }
        }
    }
    
    func onTrickle(candidate: RTCIceCandidate) {
        print("engine --- received ICE candidate from peer: \(candidate)")
        peerConnection?.add(candidate)
    }
    
    func onOffer(sessionDescription: RTCSessionDescription) {
        print("engine --- received offer, signaling state: \(String(describing: peerConnection?.signalingState))")
        peerConnection?.setRemoteDescription(sessionDescription, completionHandler: { error in
            guard error == nil else {
                print("engine --- error setting remote description for offer: \(error!)")
                return
            }
            self.peerConnection?.answer(for: RTCEngine.offerConstraints, completionHandler: { (answer, error) in
                guard error == nil else {
                    print("engine --- error creating answer: \(error!)")
                    return
                }
                self.peerConnection?.setLocalDescription(answer!, completionHandler: { error in
                    guard error == nil else {
                        print("engine --- error setting local description for answer: \(error!)")
                        return
                    }
                    self.client.sendAnswer(answer: answer!)
                })
            })
        })
    }
    
    func onNegotiateRequested() {
        negotiate()
    }
    
    func onParticipantUpdate(updates: [Livekit_ParticipantInfo]) {
        print("engine --- received participant update")
        delegate?.didUpdateParticipants(updates: updates)
    }
    
    func onLocalTrackPublished(trackPublished res: Livekit_TrackPublishedResponse) {
        guard let promise = pendingTrackResolvers.removeValue(forKey: res.cid) else {
            print("engine --- missing track resolver for: \(res.cid)")
            return
        }
        promise.fulfill(res.track)
        delegate?.didPublishLocalTrack(cid: res.cid, track: res.track)
    }
    
    func onClose(reason: String, code: UInt16) {
        print("engine --- received close event: \(reason)")
        delegate?.didDisconnect(reason: reason, code: code)
    }
    
    func onError(error: Error) {
        print("engine --- client error: \(error)")
        delegate?.didFailToConnect(error: error)
    }
}

extension RTCEngine: RTCPeerConnectionDelegate {
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        guard rtcConnected else {
            return
        }
        requestNegotiation()
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if peerConnection.iceConnectionState == .connected && !iceConnected {
            self.onICEConnected()
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("engine -- peerconn adding ICE candidate for peer: \(candidate)")
        rtcConnected ? client.sendCandidate(candidate: candidate) : pendingCandidates.append(candidate)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        delegate?.didAddDataChannel(channel: dataChannel)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track {
            delegate?.didAddTrack(track: track, streams: mediaStreams)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        switch transceiver.mediaType {
        case .video:
            print("engine --- peerconn started receiving video")
        case .audio:
            print("engine --- peerconn started receiving audio")
        case .data:
            print("engine --- peerconn started receiving data")
        default:
            break
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}
