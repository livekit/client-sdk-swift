import Foundation
import WebRTC
import Promises

let maxReconnectAttempts = 5
let maxDataPacketSize = 15000

class Engine: MulticastDelegate<EngineDelegate> {

//    typealias DelegateType = RTCEngineDelegate
//    internal let delegates = NSHashTable<AnyObject>.weakObjects()

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

    private(set) var hasPublished: Bool = false
    private(set) var publisher: Transport?
    private(set) var subscriber: Transport?
    private(set) var subscriberPrimary: Bool = false
    private var primary: Transport? {
        subscriberPrimary ? subscriber : publisher
    }

    private(set) var reliableDC: RTCDataChannel?
    private(set) var lossyDC: RTCDataChannel?

    private var connectOptions: ConnectOptions

    var connectionState: ConnectionState = .disconnected() {
        didSet {
            if oldValue == connectionState {
                return
            }
            switch connectionState {
            case .connected:

                var isReconnect = false
                if case .connecting(reconnecting: true) = oldValue {
                    isReconnect = true
                }

                notify { $0.engine(self, didConnect: isReconnect) }

//                if oldValue == .disconnected {
//                    logger.debug("publisher ICE connected")
//                    notify { $0.engineDidConnect(self) }
//                } else if oldValue == .connecting(reconnecting: true) {
//                    logger.debug("publisher ICE reconnected")
//                    notify { $0.engineDidReconnect(self) }
//                }
            case .disconnected:
                logger.info("publisher ICE disconnected")
                close()
                notify { $0.engineDidDisconnect(self) }
            default:
                break
            }
        }
    }

    var reconnectAttempts: Int = 0
    var wsReconnectTask: DispatchWorkItem?

//    private var pendingTrackResolvers: [String: Promise<Livekit_TrackInfo>] = [:]

    init(connectOptions: ConnectOptions,
         signalClient: SignalClient = SignalClient()) {
        self.connectOptions = connectOptions
        self.signalClient = signalClient
        super.init()

        signalClient.add(delegate: self)
        logger.debug("RTCEngine init")
    }

    deinit {
        logger.debug("RTCEngine deinit")
        signalClient.remove(delegate: self)
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
        default:
            logger.warning("Unknown data channel label \(dataChannel.label)")
        }
    }
    
    func connect(connectOptions: ConnectOptions? = nil) -> Promise<Void> {

        if let connectOptions = connectOptions {
            // set new connect options, if any
            self.connectOptions = connectOptions
        }

        return signalClient.connect(options: self.connectOptions).then {
            self.waitForIceConnect(transport: self.primary)
        }.then {
            self.connectionState = .connected
        }
//        wsReconnectTask = DispatchWorkItem {
//            guard self.connectionState != .disconnected else {
//                return
//            }
//            logger.info("reconnecting to signal connection, attempt \(self.reconnectAttempts)")
//            try? self.signalClient.connect(options: options, reconnect: true)
//        }
    }

    func addTrack(cid: String,
                  name: String,
                  kind: Livekit_TrackType,
                  dimensions: Dimensions? = nil) -> Promise<Livekit_TrackInfo> {

        // TODO: Check if cid already published

        signalClient.sendAddTrack(cid: cid, name: name, type: kind, dimensions: dimensions)

        return waitForPublishTrack(cid: cid)

//        return signalClient.wait(timeout: 5) { fulfill in
//            SignalClientDelegateClosures(didPublishLocalTrack: { response in
//                logger.debug("[SignalClientDelegateClosures] didPublishLocalTrack")
//                if response.cid == cid {
//                    fulfill(response.track)
//                }
//            })
//        }
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

    @discardableResult
    func reconnect(connectOptions: ConnectOptions? = nil) -> Promise<Void> {

        if let connectOptions = connectOptions {
            // set new connect options, if any
            self.connectOptions = connectOptions
        }

        guard connectionState != .disconnected() else {
            logger.debug("reconnect() already disconnected")
            return Promise(EngineError.invalidState("already disconnected"))
        }

        guard let subscriber = subscriber, let publisher = publisher else {
            return Promise(EngineError.invalidState("publisher or subscriber is null"))
        }


        logger.debug("reconnecting to signal connection, attempt', reconnectAttempts")

        if reconnectAttempts == 0 {
            connectionState = .connecting(reconnecting: true)
//            notify { $0.Reconnecting() }
        }
        reconnectAttempts += 1

        return signalClient.connect(options: self.connectOptions, reconnect: true).then { () -> Promise<Void> in
            subscriber.restartingIce = true
            if self.hasPublished {
                return publisher.createAndSendOffer()
            }
            // no-op if not published
            return Promise(())
        }.then {
            self.waitForIceConnect(transport: self.primary)
        }

//        return p
//
//        if reconnectAttempts >= maxReconnectAttempts {
//            logger.error("could not connect to signal after \(reconnectAttempts) attempts, giving up")
//            close()
////            delegate?.didDisconnect()
//            notify { $0.didDisconnect() }
//            return
//        }
//
//        if let reconnectTask = wsReconnectTask, connectionState != .disconnected {
//            var delay = Double(reconnectAttempts ^ 2) * 0.5
//            if delay > 5 {
//                delay = 5
//            }
//            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay, execute: reconnectTask)
//        }
    }

    private func handleSignalDisconnect() {
        reconnectAttempts += 1
        reconnect(connectOptions: connectOptions)
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

        guard subscriberPrimary, publisher.pc.iceConnectionState != .connected else {
            // aleady connected, no-op
            return Promise(())
        }

        negotiate()

        return waitForIceConnect(transport: publisher)

//        return publisher.wait(timeout: 3) { fulfill in
//            // temporary delegate
//            TransportDelegateClosures(onIceStateUpdated: { _, iceState in
//                if iceState == .connected {
//                    fulfill(())
//                }
//            })
//        }

//        // wait to connect...
//        return NotificationCenter.liveKit.wait(for: IceStateUpdatedEvent.self,
//                                                  timeout: 3,
//                                                  filter: { $0.target == .publisher && $0.iceState == .connected })
    }
}

// MARK: - Wait extension

extension Engine {

    func waitForIceConnect(transport: Transport?) -> Promise<Void> {

        guard let transport = transport else {
            return Promise(EngineError.invalidState("transport is nil"))
        }

        return Promise<Void> { fulfill, reject in
            // create temporary delegate
            var delegate: TransportDelegateClosures?
            delegate = TransportDelegateClosures(onIceStateUpdated: { _, iceState in
                if iceState == .connected {
                    fulfill(())
                    delegate = nil
                }
            })
            transport.add(delegate: delegate!)
        }
        // convert to timed-promise
        .timeout(5)
    }

    func waitForPublishTrack(cid: String) -> Promise<Livekit_TrackInfo> {

        return Promise<Livekit_TrackInfo> { fulfill, reject in
           // create temporary delegate
           var delegate: SignalClientDelegateClosures?
           delegate = SignalClientDelegateClosures(didPublishLocalTrack: { _, response in
               logger.debug("[SignalClientDelegateClosures] didPublishLocalTrack")
               if response.cid == cid {
                   // complete when track info received
                   fulfill(response.track)
                   delegate = nil
               }
           })
           self.signalClient.add(delegate: delegate!)
       }
       // convert to timed-promise
       .timeout(5)
    }
}

extension Engine: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) {
//        delegate?.didUpdateSpeakersSignal(speakers: speakers)
        notify { $0.engine(self, didUpdateSignal: speakers) }
    }

    func signalClient(_ signalClient: SignalClient, didConnect isReconnect: Bool) {
        logger.info("signalClient did connect")
        reconnectAttempts = 0

//        guard let publisher = self.publisher else {
//            return
//        }
        
//        subscriber?.prepareForIceRestart()

        // trigger ICE restart


        // if publisher is waiting for an answer from right now, it most likely got lost, we'll
        // reset signal state to allow it to continue
//        if let desc = publisher.pc.remoteDescription,
//           publisher.pc.signalingState == .haveLocalOffer {
//            logger.debug("have local offer but recovering to restart ICE")
//            publisher.setRemoteDescription(desc).then {
//                publisher.pc.restartIce()
////                publisher.prepareForIceRestart()
//            }
//        } else {
//            logger.debug("restarting ICE")
//            publisher.pc.restartIce()
////            /publisher.prepareForIceRestart()
//        }
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) {

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

//        delegate?.didJoin(response: joinResponse)
        notify { $0.engine(self, didReceive: joinResponse) }
    }


    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription) {

        guard let publisher = self.publisher else {
            return
        }

        logger.debug("handling server answer")
        publisher.setRemoteDescription(answer).then {
            //            if let error = error {
            //                logger.error("error setting remote description for answer: \(error)")
            //                return
            //            }
            logger.debug("successfully set remote desc")

            // when reconnecting, PeerConnection does not always recognize it's disconnected
            // as a workaround, we'll set it to be reconnected here
//            if self.connectionState == .reconnecting {
//                self.connectionState = .connected
//            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) {

        let transport = target == .publisher ? publisher : subscriber
        let result = transport?.addIceCandidate(iceCandidate)

        result?.then {
            logger.debug("did add ICE candidate")
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) {

        guard let subscriber = self.subscriber else {
            return
        }

        logger.debug("handling server offer")
        subscriber.setRemoteDescription(offer).then {
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

    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) {
//        delegate?.didUpdateParticipants(updates: updates)
        notify { $0.engine(self, didUpdate: participants) }
    }

    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) {

        logger.debug("received track published confirmation for: \(localTrack.track.sid)")
//        guard let promise = pendingTrackResolvers.removeValue(forKey: localTrack.cid) else {
//            logger.error("missing track resolver for: \(localTrack.cid)")
//            return
//        }
//        promise.fulfill(localTrack.track)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) {
//        delegate?.remoteMuteDidChange(trackSid: trackSid, muted: muted)
        notify { $0.engine(self, didUpdateRemoteMute: trackSid, muted: muted) }
    }

    func signalClientDidLeave(_ signaClient: SignalClient) {
        close()
//        delegate?.didDisconnect()
        notify { $0.engineDidDisconnect(self) }
    }

    func signalClient(_ signalClient: SignalClient, didClose reason: String, code: UInt16) {
        logger.debug("signal connection closed with code: \(code), reason: \(reason)")
        handleSignalDisconnect()
    }

    func signalClient(_ signalClient: SignalClient, didFailConnection error: Error) {
        logger.debug("signal connection error: \(error)")
//        delegate?.didFailToConnect(error: error)
        notify { $0.engine(self, didFailConnection: error) }
    }
}

extension Engine: RTCDataChannelDelegate {

    func dataChannelDidChangeState(_: RTCDataChannel) {}

    func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {

        guard let dataPacket = try? Livekit_DataPacket(contiguousBytes: buffer.data) else {
            logger.error("could not decode data message")
            return
        }

        switch dataPacket.value {
        case .speaker(let update):
//            delegate?.didUpdateSpeakersEngine(speakers: update.speakers)
            notify { $0.engine(self, didUpdateEngine: update.speakers) }
        case .user(let userPacket):
//            delegate?.didReceive(userPacket: userPacket, kind: dataPacket.kind)
            notify { $0.engine(self, didReceive: userPacket) }
        default:
            return
        }
    }
}

extension Engine: TransportDelegate {

    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate) {
        logger.debug("[PCTransportDelegate] didGenerate iceCandidate")
        try? signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
    }

    func transport(_ transport: Transport, didUpdate iceState: RTCIceConnectionState) {
        logger.debug("[PCTransportDelegate] didUpdate iceState")
        if transport.primary {
            if iceState == .connected {
                self.connectionState = .connected
            } else if iceState == .failed {
                self.connectionState = .disconnected()
            }
        }
    }

    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        logger.debug("[PCTransportDelegate] did add track")
        if transport.target == .subscriber {
//            delegate?.didAddTrack(track: track, streams: streams)
            notify { $0.engine(self, didAdd: track, streams: streams) }
        }
    }

    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {
        logger.debug("[PCTransportDelegate] did add track] did open datachannel")
        if subscriberPrimary, transport.target == .subscriber {
            onReceived(dataChannel: dataChannel)
        }
    }
}
