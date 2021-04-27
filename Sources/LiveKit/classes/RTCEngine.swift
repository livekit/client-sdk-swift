//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/4/20.
//

import Foundation
import Promises
import WebRTC

let maxWSRetries = 5
let reliableDataChannelLabel = "_reliable"
let lossyDataChannelLabel = "_lossy"
let maxDataPacketSize = 15000

class RTCEngine: NSObject {
    static var offerConstraints = RTCMediaConstraints(mandatoryConstraints: [
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
        kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
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

    static let defaultIceServers = ["stun:stun.l.google.com:19302",
                                    "stun:stun1.l.google.com:19302"]

    var publisher: PeerConnectionTransport?
    var subscriber: PeerConnectionTransport?
    var publisherDelegate: PublisherTransportDelegate
    var subscriberDelegate: SubscriberTransportDelegate
    var client: RTCClient
    var reliableDC: RTCDataChannel?
    var lossyDC: RTCDataChannel?

    var rtcConnected: Bool = false
    var iceConnected: Bool = false {
        didSet {
            if oldValue == iceConnected {
                return
            }
            if iceConnected {
                logger.info("publisher ICE connected")
                delegate?.ICEDidConnect()
            } else {
                logger.info("publisher ICE disconnected")
                close()
                delegate?.didDisconnect()
            }
        }
    }

    var wsRetries: Int = 0
    var wsReconnectTask: DispatchWorkItem?

    private var pendingTrackResolvers: [String: Promise<Livekit_TrackInfo>] = [:]

    weak var delegate: RTCEngineDelegate?

    init(client: RTCClient) {
        self.client = client
        publisherDelegate = PublisherTransportDelegate()
        subscriberDelegate = SubscriberTransportDelegate()
        super.init()

        publisherDelegate.engine = self
        subscriberDelegate.engine = self
        client.delegate = self
    }

    func join(options: ConnectOptions) {
        client.join(options: options)
        wsReconnectTask = DispatchWorkItem {
            guard self.iceConnected else {
                return
            }
            logger.info("reconnecting to signal connection, attempt \(self.wsRetries)")
            var reconnectOptions = options
            reconnectOptions.reconnect = true
            self.client.join(options: reconnectOptions)
        }
    }

    func addTrack(cid: String, name: String, kind: Livekit_TrackType) throws -> Promise<Livekit_TrackInfo> {
        if pendingTrackResolvers[cid] != nil {
            throw TrackError.duplicateTrack("Track with the same ID (\(cid)) has already been published!")
        }

        let promise = Promise<Livekit_TrackInfo>.pending()
        pendingTrackResolvers[cid] = promise
        client.sendAddTrack(cid: cid, name: name, type: kind)
        return promise
    }

    func updateMuteStatus(trackSid: String, muted: Bool) {
        client.sendMuteTrack(trackSid: trackSid, muted: muted)
    }

    func close() {
        publisher?.close()
        subscriber?.close()
        client.close()
        rtcConnected = false
    }

    func negotiate() {
        publisher?.peerConnection.offer(for: RTCEngine.offerConstraints, completionHandler: { offer, error in
            guard error == nil else {
                logger.error("could not create offer: \(error!)")
                return
            }
            guard let sdp = offer else {
                logger.error("offer is unexpectedly missing during negotiation")
                return
            }
            self.publisher?.peerConnection.setLocalDescription(sdp, completionHandler: { error in
                guard error == nil else {
                    logger.error("error setting local description: \(error!)")
                    return
                }
                self.client.sendOffer(offer: sdp)
            })
        })
    }

    func reconnect() {
        if wsRetries >= maxWSRetries {
            logger.error("could not connect to signal after \(wsRetries) attempts, giving up")
            close()
            delegate?.didDisconnect()
            return
        }

        if iceConnected, wsReconnectTask != nil {
            var delay = Double(wsRetries ^ 2) * 0.5
            if delay > 5 {
                delay = 5
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: wsReconnectTask!)
        }
    }

    private func onRTCConnected() {
        rtcConnected = true
    }

    private func handleSignalDisconnect() {
        wsRetries += 1
        reconnect()
    }
}

extension RTCEngine: RTCClientDelegate {
    func onActiveSpeakersChanged(speakers: [Livekit_SpeakerInfo]) {
        delegate?.didUpdateSpeakers(speakers: speakers)
    }

    func onReconnect() {
        logger.info("reconnect success, restarting ICE")
        wsRetries = 0

        // trigger ICE restart
        publisher?.peerConnection.restartIce()
        if let sub = subscriber {
            if sub.peerConnection.connectionState == .connected {
                sub.peerConnection.restartIce()
            }
        }
    }

    func onJoin(info: Livekit_JoinResponse) {
        // create publisher and subscribers
        let config = RTCConfiguration()
        config.iceServers = []
        for s in info.iceServers {
            var username: String?
            var credential: String?
            if s.username != "" {
                username = s.username
            }
            if s.credential != "" {
                credential = s.credential
            }
            config.iceServers.append(RTCIceServer(urlStrings: s.urls, username: username, credential: credential))
            logger.debug("ICE servers: \(s.urls)")
        }

        if config.iceServers.count == 0 {
            config.iceServers = [RTCIceServer(urlStrings: RTCEngine.defaultIceServers)]
        }

        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.candidateNetworkPolicy = .all
        config.tcpCandidatePolicy = .enabled
        config.iceTransportPolicy = .all

        publisher = PeerConnectionTransport(config: config, delegate: publisherDelegate)
        subscriber = PeerConnectionTransport(config: config, delegate: subscriberDelegate)

        let reliableConfig = RTCDataChannelConfiguration()
        reliableConfig.isOrdered = true
        reliableDC = publisher!.peerConnection.dataChannel(forLabel: reliableDataChannelLabel,
                                                           configuration: reliableConfig)
        reliableDC?.delegate = self
        let lossyConfig = RTCDataChannelConfiguration()
        lossyConfig.isOrdered = true
        lossyConfig.maxRetransmits = 1
        lossyDC = publisher!.peerConnection.dataChannel(forLabel: lossyDataChannelLabel,
                                                        configuration: lossyConfig)
        lossyDC?.delegate = self

        publisher!.peerConnection.offer(for: RTCEngine.offerConstraints, completionHandler: { sdp, error in
            guard error == nil else {
                logger.error("could not create publisher offer: \(error!)")
                return
            }
            guard let desc = sdp else {
                logger.error("could not find sdp in publisher offer")
                return
            }
            self.publisher!.peerConnection.setLocalDescription(desc, completionHandler: { error in
                guard error == nil else {
                    logger.error("error setting local description: \(error!)")
                    return
                }
                self.client.sendOffer(offer: desc)
            })
        })

        delegate?.didJoin(response: info)
    }

    func onAnswer(sessionDescription: RTCSessionDescription) {
        guard let publisher = self.publisher else {
            return
        }
        logger.debug("handling server answer")
        publisher.setRemoteDescription(sessionDescription) { error in
            guard error == nil else {
                logger.error("error setting remote description for answer: \(error!)")
                return
            }
            if !self.rtcConnected {
                self.onRTCConnected()
            }
            logger.debug("successfully set remote desc")
        }
    }

    func onTrickle(candidate: RTCIceCandidate, target: Livekit_SignalTarget) {
        if target == .publisher {
            publisher?.addIceCandidate(candidate: candidate)
        } else {
            subscriber?.addIceCandidate(candidate: candidate)
        }
    }

    func onOffer(sessionDescription: RTCSessionDescription) {
        guard let subscriber = self.subscriber else {
            return
        }

        logger.debug("handling server offer")
        subscriber.setRemoteDescription(sessionDescription, completionHandler: { error in
            guard error == nil else {
                logger.error("error setting subscriber remote description for offer: \(error!)")
                return
            }
            subscriber.peerConnection.answer(for: RTCEngine.offerConstraints, completionHandler: { answer, error in
                guard error == nil else {
                    logger.error("error answering subscriber: \(error!)")
                    return
                }
                guard let ans = answer else {
                    logger.error("unexpectedly missing answer for subscriber")
                    return
                }
                subscriber.peerConnection.setLocalDescription(ans, completionHandler: { error in
                    guard error == nil else {
                        logger.error("error setting subscriber local description for answer: \(error!)")
                        return
                    }
                    logger.debug("sending client answer")
                    self.client.sendAnswer(answer: ans)
                })
            })
        })
    }

    func onParticipantUpdate(updates: [Livekit_ParticipantInfo]) {
        delegate?.didUpdateParticipants(updates: updates)
    }

    func onLocalTrackPublished(trackPublished: Livekit_TrackPublishedResponse) {
        logger.debug("received track published confirmation for: \(trackPublished.track.sid)")
        guard let promise = pendingTrackResolvers.removeValue(forKey: trackPublished.cid) else {
            logger.error("missing track resolver for: \(trackPublished.cid)")
            return
        }
        promise.fulfill(trackPublished.track)
    }

    func onLeave() {
        close()
        delegate?.didDisconnect()
    }

    func onClose(reason: String, code: UInt16) {
        logger.debug("signal connection closed with code: \(code), reason: \(reason)")
        handleSignalDisconnect()
    }

    func onError(error: Error) {
        logger.debug("signal connection error: \(error)")
        delegate?.didFailToConnect(error: error)
    }
}

extension RTCEngine: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_: RTCDataChannel) {
        // do nothing
    }

    func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let dataPacket: Livekit_DataPacket
        do {
            dataPacket = try Livekit_DataPacket(contiguousBytes: buffer.data)
        } catch {
            logger.error("could not decode data message \(error)")
            return
        }

        switch dataPacket.value {
        case let .speaker(update):
            delegate?.didUpdateSpeakers(speakers: update.speakers)
        case let .user(userPacket):
            delegate?.didReceive(packet: userPacket, kind: dataPacket.kind)
        default:
            return
        }
    }
}
