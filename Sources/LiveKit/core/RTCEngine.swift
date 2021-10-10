//
// LiveKit
// https://livekit.io
//

import Foundation
import Promises
import WebRTC

let maxWSRetries = 5
let maxDataPacketSize = 15000

class RTCEngine: NSObject {

    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let simulcastFactory = RTCVideoEncoderFactorySimulcast(primary: encoderFactory,
                                                               fallback: encoderFactory)
        return RTCPeerConnectionFactory(encoderFactory: simulcastFactory,
                                        decoderFactory: decoderFactory)
    }()

    let signalClient: SignalClient

    // read-only
    private(set) var publisher: Transport?
    private(set) var subscriber: Transport?
    private(set) var subscriberPrimary: Bool = false
    private(set) var hasPublished: Bool = false

    // computed
    private var primary: Transport? {
        subscriberPrimary ? subscriber : publisher
    }

    private(set) var reliableDC: RTCDataChannel?
    private(set) var lossyDC: RTCDataChannel?

    var iceState: ConnectionState = .disconnected {
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

    private var listenTokens: [NSObjectProtocol] = []

    init(client: SignalClient? = nil) {
        self.signalClient = client ?? SignalClient()
        super.init()
        self.signalClient.delegate = self

        logger.debug("RTCEngine init")
//        setUpListeners()
    }

    deinit {
        logger.debug("RTCEngine deinit")

//        for token in listenTokens {
//            NotificationCenter.liveKit.removeObserver(token)
//        }
    }

//    private func setUpListeners() {

//        let l1 = NotificationCenter.liveKit.listen(for: IceCandidateEvent.self) { [weak self] event in
//            logger.debug("[Event] \(event)")
//            try? self?.signalClient.sendCandidate(candidate: event.iceCandidate, target: event.target)
//        }
//
//        let l2 = NotificationCenter.liveKit.listen(for: IceStateUpdatedEvent.self) { [weak self] event in
//            logger.debug("[Event] \(event)")
//            if event.primary {
//                if event.iceState == .connected {
//                    self?.iceState = .connected
//                } else if event.iceState == .failed {
//                    self?.iceState = .disconnected
//                }
//            }
//        }
//
//        let l3 = NotificationCenter.liveKit.listen(for: ReceivedTrackEvent.self) { [weak self] event in
//            logger.debug("[Event] \(event)")
//            if event.target == .subscriber {
//                self?.delegate?.didAddTrack(track: event.track, streams: event.streams)
//            }
//        }
//
//        let l4 = NotificationCenter.liveKit.listen(for: DataChannelEvent.self) { event in
//            logger.debug("[Event] \(event)")
//            if self.subscriberPrimary, event.target == .subscriber {
//                self.onReceived(dataChannel: event.dataChannel)
//            }
//        }

//        listenTokens += [l1, l2, l3, l4]
//    }

    private func onReceived(dataChannel: RTCDataChannel) {

        logger.debug("Server opened data channel \(dataChannel.label)")

        switch dataChannel.label {
        case RTCDataChannel.labels.reliable:
            reliableDC = dataChannel
            reliableDC?.delegate = self
        case RTCDataChannel.labels.lossy:
            lossyDC = dataChannel
            lossyDC?.delegate = self
        default: break
        }
    }


    func join(options: ConnectOptions) {
        try? signalClient.join(options: options)
        wsReconnectTask = DispatchWorkItem {
            guard self.iceState != .disconnected else {
                return
            }
            logger.info("reconnecting to signal connection, attempt \(self.wsRetries)")
            try? self.signalClient.join(options: options, reconnect: true)
        }
    }

    func addTrack(cid: String, name: String, kind: Livekit_TrackType, dimensions: Dimensions? = nil) -> Promise<Livekit_TrackInfo> {

        if pendingTrackResolvers[cid] != nil {
            return Promise(TrackError.duplicateTrack("Track with the same ID (\(cid)) has already been published!"))
        }

        let promise = Promise<Livekit_TrackInfo>.pending()
        pendingTrackResolvers[cid] = promise
        signalClient.sendAddTrack(cid: cid, name: name, type: kind, dimensions: dimensions)
        return promise
    }

    func updateMuteStatus(trackSid: String, muted: Bool) {
        signalClient.sendMuteTrack(trackSid: trackSid, muted: muted)
    }

    func close() {
        publisher?.close()
        subscriber?.close()
        signalClient.close()
    }

    func negotiate() {

        guard let publisher = publisher else {
            logger.debug("negotiate() publisher is nil")
            return
        }

        hasPublished = true
        publisher.negotiate()
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

    func sendDataPacket(packet: Livekit_DataPacket) -> Promise<Void> {

        guard let data = try? packet.serializedData() else {
            return Promise(InternalError.parse("Failed to serialize data packet"))
        }

        func send() -> Promise<Void>{

            Promise<Void>{ complete, fail in
                let rtcData = RTCDataBuffer(data: data, isBinary: true)
                let dc = packet.kind == .lossy ? self.lossyDC : self.reliableDC
                if let dc = dc {
                    // TODO: Check return value
                    dc.sendData(rtcData)
                }
                complete(())
            }
        }

        return ensurePublisherConnected().then { _ in send() }
    }

    private func ensurePublisherConnected () -> Promise<Void> {

        guard let publisher = publisher else {
            return Promise(EngineError.invalidState("publisher is nil"))
        }

        guard subscriberPrimary,
              publisher.pc.iceConnectionState != .connected else {
            // aleady connected
            return Promise(())
        }

        negotiate()

        return [publisher].wait(timeout: 3) { fulfill in
            // temporary delegate
            TransportDelegateClosure(onIceStateUpdated: { _, iceState in
                if iceState == .connected {
                    fulfill()
                }
            })
        }

//        // wait to connect...
//        return NotificationCenter.liveKit.wait(for: IceStateUpdatedEvent.self,
//                                                  timeout: 3,
//                                                  filter: { $0.target == .publisher && $0.iceState == .connected })
    }
}

extension RTCEngine: SignalClientDelegate {

    func onSignalActiveSpeakersChanged(speakers: [Livekit_SpeakerInfo]) {
        delegate?.didUpdateSpeakersSignal(speakers: speakers)
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
        config.update(iceServers: joinResponse.iceServers)

        do {
            subscriber = try Transport(config: config,
                                         target: .subscriber,
                                         primary: subscriberPrimary,
                                         delegate: self)

            publisher = try Transport(config: config,
                                        target: .publisher,
                                        primary: !subscriberPrimary,
                                        delegate: self)

            publisher?.onOffer = { offer in
                logger.debug("publisher onOffer")
                try? self.signalClient.sendOffer(offer: offer)
            }

            // data over pub channel for backwards compatibility
            let reliableConfig = RTCDataChannelConfiguration()
            reliableConfig.isOrdered = true
            reliableDC = publisher?.pc.dataChannel(forLabel: RTCDataChannel.labels.reliable,
                                                   configuration: reliableConfig)
            reliableDC?.delegate = self

            let lossyConfig = RTCDataChannelConfiguration()
            lossyConfig.isOrdered = true
            lossyConfig.maxRetransmits = 0
            lossyDC = publisher?.pc.dataChannel(forLabel: RTCDataChannel.labels.lossy,
                                                configuration: lossyConfig)
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
            subscriber.pc.createAnswerPromise()
        }.then { answer in
            subscriber.pc.setLocalDescriptionPromise(answer)
        }.then { answer in
            try? self.signalClient.sendAnswer(answer: answer)
        }
            //            if let error = error {
            //                logger.error("error setting subscriber remote description for offer: \(error)")
            //                return
            //            }
//            let constraints: Dictionary<String, String> = [:]
//            let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
//                                                       optionalConstraints: nil)
//            subscriber.pc.answer(for: mediaConstraints, completionHandler: { answer, error in
//                if let error = error {
//                    logger.error("error answering subscriber: \(error)")
//                    return
//                }
//                guard let ans = answer else {
//                    logger.error("unexpectedly missing answer for subscriber")
//                    return
//                }
//                subscriber.pc.setLocalDescription(ans, completionHandler: { error in
//                    if let error = error {
//                        logger.error("error setting subscriber local description for answer: \(error)")
//                        return
//                    }
//                    logger.debug("sending client answer")
//                    try? self.signalClient.sendAnswer(answer: ans)
//                })
//            })
//        }
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

    func dataChannelDidChangeState(_: RTCDataChannel) {}

    func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {

        guard let dataPacket = try? Livekit_DataPacket(contiguousBytes: buffer.data) else {
            logger.error("could not decode data message")
            return
        }

        switch dataPacket.value {
        case .speaker(let update):
            delegate?.didUpdateSpeakersEngine(speakers: update.speakers)
        case .user(let userPacket):
            delegate?.didReceive(userPacket: userPacket, kind: dataPacket.kind)
        default:
            return
        }
    }
}

extension RTCEngine: TransportDelegate {

    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate) {
        logger.debug("[PCTransportDelegate] didGenerate iceCandidate")
        try? signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
    }

    func transport(_ transport: Transport, didUpdate iceState: RTCIceConnectionState) {
        logger.debug("[PCTransportDelegate] didUpdate iceState")
        if transport.primary {
            if iceState == .connected {
                self.iceState = .connected
            } else if iceState == .failed {
                self.iceState = .disconnected
            }
        }
    }

    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        logger.debug("[PCTransportDelegate] did add track")
        if transport.target == .subscriber {
            delegate?.didAddTrack(track: track, streams: streams)
        }
    }

    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {
        logger.debug("[PCTransportDelegate] did add track] did open datachannel")
        if subscriberPrimary, transport.target == .subscriber {
            onReceived(dataChannel: dataChannel)
        }
    }
}
