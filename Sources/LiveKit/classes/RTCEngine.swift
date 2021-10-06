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

enum ICEState {
    case disconnected
    case connected
    case reconnecting
}

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
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let simulcastFactory = RTCVideoEncoderFactorySimulcast(primary: encoderFactory, fallback: encoderFactory)
        return RTCPeerConnectionFactory(encoderFactory: simulcastFactory, decoderFactory: decoderFactory)
    }()

    static let defaultIceServers = ["stun:stun.l.google.com:19302",
                                    "stun:stun1.l.google.com:19302"]

    // read-only
    private(set) var publisher: PCTransport?
    private(set) var subscriber: PCTransport?
    private(set) var subscriberPrimary: Bool = false
    private(set) var hasPublished: Bool = false

    // computed
    var primary: PCTransport? {
        subscriberPrimary ? subscriber : publisher
    }

    var publisherDelegate: PublisherTransportDelegate
    var subscriberDelegate: SubscriberTransportDelegate
    var client: SignalClient
    var reliableDC: RTCDataChannel?
    var lossyDC: RTCDataChannel?

    var iceState: ICEState = .disconnected {
        didSet {
            if oldValue == iceState {
                return
            }
            switch iceState {
            case .connected:
                if oldValue == .disconnected {
                    logger.debug("publisher ICE connected")
                    delegate?.ICEDidConnect()
                } else if oldValue == .reconnecting {
                    logger.debug("publisher ICE reconnected")
                    delegate?.ICEDidReconnect()
                }
            case .disconnected:
                logger.info("publisher ICE disconnected")
                close()
                delegate?.didDisconnect()
            default:
                break
            }
        }
    }

    var wsRetries: Int = 0
    var wsReconnectTask: DispatchWorkItem?

    private var pendingTrackResolvers: [String: Promise<Livekit_TrackInfo>] = [:]

    weak var delegate: RTCEngineDelegate?

    init(client: SignalClient? = nil) {

        self.client = client ?? SignalClient()

        publisherDelegate = PublisherTransportDelegate()
        subscriberDelegate = SubscriberTransportDelegate()
        super.init()

        publisherDelegate.engine = self
        subscriberDelegate.engine = self
        self.client.delegate = self
    }

//    @objc func getStatsTimer() {
//        print("getting stats...")
//        print("------------------------------------------------------------")
//        publisher?.pc.stats(for: nil, statsOutputLevel: .standard, completionHandler: { result in
//            let types = result.map{ $0.type }
//            print(types)
////            let v = rep.filter { $0.type == "ssrc" }
//            for entry in result {
//                print(entry.values)
//            }
//        })
//    }


    func join(options: ConnectOptions) {
        try? client.join(options: options)
        wsReconnectTask = DispatchWorkItem {
            guard self.iceState != .disconnected else {
                return
            }
            logger.info("reconnecting to signal connection, attempt \(self.wsRetries)")
//            var reconnectOptions = options
//            reconnectOptions.reconnect = true
            try? self.client.join(options: options, reconnect: true)
        }
    }

    func addTrack(cid: String, name: String, kind: Livekit_TrackType, dimensions: Dimensions? = nil) throws -> Promise<Livekit_TrackInfo> {
        if pendingTrackResolvers[cid] != nil {
            throw TrackError.duplicateTrack("Track with the same ID (\(cid)) has already been published!")
        }

        let promise = Promise<Livekit_TrackInfo>.pending()
        pendingTrackResolvers[cid] = promise
        client.sendAddTrack(cid: cid, name: name, type: kind, dimensions: dimensions)
        return promise
    }

    func updateMuteStatus(trackSid: String, muted: Bool) {
        client.sendMuteTrack(trackSid: trackSid, muted: muted)
    }

    func close() {
        publisher?.close()
        subscriber?.close()
        client.close()
    }

    func negotiate() {

        guard let publisher = publisher else {
            logger.debug("negotiate() publisher is nil")
            return
        }

        hasPublished = true
        publisher.negotiate()

//        var constraints = [
//            kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
//            kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
//        ]
//        if iceState == .reconnecting {
//            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
//        }
//        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints, optionalConstraints: nil)
//
//        publisher?.pc.offer(for: mediaConstraints, completionHandler: { offer, error in
//            if let error = error {
//                logger.error("could not create offer: \(error)")
//                return
//            }
//            guard let sdp = offer else {
//                logger.error("offer is unexpectedly missing during negotiation")
//                return
//            }
//            self.publisher?.pc.setLocalDescription(sdp, completionHandler: { error in
//                if let error = error {
//                    logger.error("error setting local description: \(error)")
//                    return
//                }
//                try? self.client.sendOffer(offer: sdp)
//            })
//        })
    }

    func reconnect() {
        if wsRetries >= maxWSRetries {
            logger.error("could not connect to signal after \(wsRetries) attempts, giving up")
            close()
            delegate?.didDisconnect()
            return
        }

        if let reconnectTask = wsReconnectTask, iceState != .disconnected {
            var delay = Double(wsRetries ^ 2) * 0.5
            if delay > 5 {
                delay = 5
            }
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay, execute: reconnectTask)
        }
    }

    private func handleSignalDisconnect() {
        wsRetries += 1
        reconnect()
    }
}

extension RTCEngine: SignalClientDelegate {

    func onSignalActiveSpeakersChanged(speakers: [Livekit_SpeakerInfo]) {
        delegate?.didUpdateSpeakers(speakers: speakers)
    }

    func onSignalReconnect() {
        logger.info("signal reconnect success")
        wsRetries = 0
        
        guard let publisher = self.publisher else {
            return
        }
        
        subscriber?.prepareForIceRestart()

        // trigger ICE restart
        iceState = .reconnecting
        // if publisher is waiting for an answer from right now, it most likely got lost, we'll
        // reset signal state to allow it to continue
        if let desc = publisher.pc.remoteDescription,
           publisher.pc.signalingState == .haveLocalOffer {
            logger.debug("have local offer but recovering to restart ICE")
            publisher.setRemoteDescription(desc).then {
                publisher.pc.restartIce()
                publisher.prepareForIceRestart()
            }
        } else {
            logger.debug("restarting ICE")
            publisher.pc.restartIce()
            publisher.prepareForIceRestart()
        }
    }

    func onSignalJoin(joinResponse: Livekit_JoinResponse) {

        guard subscriber == nil, publisher == nil else {
            logger.debug("onJoin() already configured")
            return
        }

        // protocol v3
        subscriberPrimary = joinResponse.subscriberPrimary

        // create publisher and subscribers
        let config = RTCConfiguration.liveKitDefault()

        config.iceServers = []
        for s in joinResponse.iceServers {
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

        do {
            publisher = try PCTransport(config: config, target: .publisher, delegate: publisherDelegate)
            subscriber = try PCTransport(config: config, target: .subscriber, delegate: subscriberDelegate)
//            publisher = pub
//            subscriber = sub

            let reliableConfig = RTCDataChannelConfiguration()
            reliableConfig.isOrdered = true
            reliableDC = publisher?.pc.dataChannel(forLabel: reliableDataChannelLabel, configuration: reliableConfig)
            reliableDC?.delegate = self

            let lossyConfig = RTCDataChannelConfiguration()
            lossyConfig.isOrdered = true
            lossyConfig.maxRetransmits = 1
            lossyDC = publisher?.pc.dataChannel(forLabel: lossyDataChannelLabel, configuration: lossyConfig)
            lossyDC?.delegate = self

        } catch {
            //
        }

        if (subscriberPrimary) {
            // lazy negotiation for protocol v3
            negotiate()
        }

        delegate?.didJoin(response: joinResponse)
    }

    func onSignalAnswer(sessionDescription: RTCSessionDescription) {
        guard let publisher = self.publisher else {
            return
        }
        logger.debug("handling server answer")
        publisher.setRemoteDescription(sessionDescription).then {
//            if let error = error {
//                logger.error("error setting remote description for answer: \(error)")
//                return
//            }
            logger.debug("successfully set remote desc")

            // when reconnecting, PeerConnection does not always recognize it's disconnected
            // as a workaround, we'll set it to be reconnected here
            if self.iceState == .reconnecting {
                self.iceState = .connected
            }
        }
    }

    func onSignalTrickle(candidate: RTCIceCandidate, target: Livekit_SignalTarget) {

        let transport = target == .publisher ? publisher : subscriber
        let result = transport?.addIceCandidate(candidate)

        result?.then {
            logger.debug("did add ICE candidate")
        }
    }

    func onSignalOffer(sessionDescription: RTCSessionDescription) {
        guard let subscriber = self.subscriber else {
            return
        }

        logger.debug("handling server offer")
        subscriber.setRemoteDescription(sessionDescription).then {
//            if let error = error {
//                logger.error("error setting subscriber remote description for offer: \(error)")
//                return
//            }
            let constraints: Dictionary<String, String> = [:]
            let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                       optionalConstraints: nil)
            subscriber.pc.answer(for: mediaConstraints, completionHandler: { answer, error in
                if let error = error {
                    logger.error("error answering subscriber: \(error)")
                    return
                }
                guard let ans = answer else {
                    logger.error("unexpectedly missing answer for subscriber")
                    return
                }
                subscriber.pc.setLocalDescription(ans, completionHandler: { error in
                    if let error = error {
                        logger.error("error setting subscriber local description for answer: \(error)")
                        return
                    }
                    logger.debug("sending client answer")
                    try? self.client.sendAnswer(answer: ans)
                })
            })
        }
    }

    func onSignalParticipantUpdate(updates: [Livekit_ParticipantInfo]) {
        delegate?.didUpdateParticipants(updates: updates)
    }

    func onSignalLocalTrackPublished(trackPublished: Livekit_TrackPublishedResponse) {
        logger.debug("received track published confirmation for: \(trackPublished.track.sid)")
        guard let promise = pendingTrackResolvers.removeValue(forKey: trackPublished.cid) else {
            logger.error("missing track resolver for: \(trackPublished.cid)")
            return
        }
        promise.fulfill(trackPublished.track)
    }

    func onSignalRemoteMuteChanged(trackSid: String, muted: Bool) {
        delegate?.remoteMuteDidChange(trackSid: trackSid, muted: muted)
    }

    func onSignalLeave() {
        close()
        delegate?.didDisconnect()
    }

    func onSignalClose(reason: String, code: UInt16) {
        logger.debug("signal connection closed with code: \(code), reason: \(reason)")
        handleSignalDisconnect()
    }

    func onSignalError(error: Error) {
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
