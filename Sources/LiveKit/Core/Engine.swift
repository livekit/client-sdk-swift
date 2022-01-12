import Foundation
import WebRTC
import Promises

internal class Engine: MulticastDelegate<EngineDelegate> {

    // Reference to Room
    public let room: Room

    public let signalClient: SignalClient

    private(set) var hasPublished: Bool = false
    private(set) var publisher: Transport?
    private(set) var subscriber: Transport?
    private(set) var subscriberPrimary: Bool = false
    private var primary: Transport? {
        subscriberPrimary ? subscriber : publisher
    }

    private(set) var dcReliablePub: RTCDataChannel?
    private(set) var dcLossyPub: RTCDataChannel?
    private(set) var dcReliableSub: RTCDataChannel?
    private(set) var dcLossySub: RTCDataChannel?

    internal var url: String?
    internal var token: String?

    public private(set) var connectionState: ConnectionState = .disconnected() {
        // automatically notify changes
        didSet {
            guard oldValue != connectionState else { return }
            logger.debug("connectionState updated \(oldValue) -> \(self.connectionState)")
            switch connectionState {
            case .connected: notify { $0.engine(self, didConnect: oldValue.isReconnecting) }
            case .disconnected: notify { $0.engineDidDisconnect(self) }
            default: break
            }
            notify { $0.engine(self, didUpdate: self.connectionState) }
        }
    }

    public init(room: Room,
                signalClient: SignalClient = SignalClient()) {
        self.room = room
        self.signalClient = signalClient
        super.init()

        add(delegate: room)

        signalClient.add(delegate: self)
        logger.debug("RTCEngine init")
    }

    deinit {
        logger.debug("RTCEngine deinit")
        // signalClient.remove(delegate: self)
    }

    public func connect(_ url: String,
                        _ token: String) -> Promise<Void> {

        guard connectionState != .connected else {
            logger.debug("already connected")
            return Promise(EngineError.state(message: "already connected"))
        }

        // reset internal vars
        self.url = nil
        self.token = nil

        self.connectionState = .connecting(isReconnecting: false)

        return signalClient.connect(url,
                                    token,
                                    connectOptions: room.connectOptions).then {
                                        // wait for join response
                                        self.signalClient.waitReceiveJoinResponse()
                                    }.then { joinResponse in
                                        // set up peer connections
                                        self.configureTransports(joinResponse: joinResponse)
                                    }.then {
                                        // wait for peer connections to connect
                                        self.waitForIceConnect(transport: self.primary)
                                    }.then {
                                        // connect sequence successful
                                        logger.debug("connect sequence completed")

                                        // update internal vars (only if connect succeeded)
                                        self.url = url
                                        self.token = token

                                        self.connectionState = .connected
                                    }
    }

    @discardableResult
    private func reconnect() -> Promise<Void> {

        guard let url = url,
              let token = token else {
            logger.debug("reconnect() must be called with connected state")
            return Promise(EngineError.state(message: "reconnect() called with no url or token"))
        }

        guard case .connected = connectionState else {
            logger.debug("reconnect() must be called with connected state")
            return Promise(EngineError.state(message: "reconnect() called with invalid state"))
        }

        guard subscriber != nil, publisher != nil else {
            return Promise(EngineError.state(message: "publisher or subscriber is null"))
        }

        connectionState = .connecting(isReconnecting: true)

        func reconnectSequence() -> Promise<Void> {

            signalClient.connect(url,
                                 token,
                                 connectOptions: room.connectOptions,
                                 reconnect: true).then {
                                    self.waitForIceConnect(transport: self.primary)
                                 }.then { () -> Promise<Void> in
                                    self.subscriber?.restartingIce = true

                                    // only if published, continue...
                                    guard let publisher = self.publisher, self.hasPublished else {
                                        return Promise(())
                                    }

                                    return publisher.createAndSendOffer(iceRestart: true).then {
                                        self.waitForIceConnect(transport: publisher)
                                    }
                                 }
        }

        let delay: TimeInterval = 1
        return retry(attempts: 5, delay: delay) { remainingAttempts, _ in
            logger.debug("re-connecting in \(delay)second(s), \(remainingAttempts) remaining attempts...")
            // only retry if still reconnecting state (not disconnected)
            return .connecting(isReconnecting: true) == self.connectionState
        } _: {
            // try to re-connect
            reconnectSequence()
        }.then {
            // re-connect sequence successful
            logger.debug("re-connect sequence completed")
            self.connectionState = .connected
        }.catch { _ in
            // finally disconnect if all attempts fail
            self.disconnect()
        }
    }

    public func disconnect() {

        guard .disconnected() != connectionState else {
            logger.warning("close() already disconnected")
            return
        }

        url = nil
        token = nil

        connectionState = .disconnected()

        publisher?.close()
        publisher = nil

        subscriber?.close()
        subscriber = nil

        signalClient.close()

        notify { $0.engineDidDisconnect(self) }
    }

    private func onReceived(dataChannel: RTCDataChannel) {

        logger.debug("Server opened data channel \(dataChannel.label)")

        switch dataChannel.label {
        case RTCDataChannel.labels.reliable:
            dcReliableSub = dataChannel
            dcReliableSub?.delegate = self
        case RTCDataChannel.labels.lossy:
            dcLossySub = dataChannel
            dcLossySub?.delegate = self
        default:
            logger.warning("Unknown data channel label \(dataChannel.label)")
        }
    }

    public func addTrack(cid: String,
                         name: String,
                         kind: Livekit_TrackType,
                         source: Livekit_TrackSource = .unknown,
                         _ populator: (inout Livekit_AddTrackRequest) -> Void) -> Promise<Livekit_TrackInfo> {

        // TODO: Check if cid already published

        signalClient.sendAddTrack(cid: cid, name: name, type: kind, source: source, populator)

        return waitForPublishTrack(cid: cid)
    }

    internal func publisherShouldNegotiate() {

        guard let publisher = publisher else {
            logger.debug("negotiate() publisher is nil")
            return
        }

        hasPublished = true
        publisher.negotiate()
    }

    internal func publisherDataChannel(for reliability: Reliability) -> RTCDataChannel? {
        reliability == .reliable ? dcReliablePub : dcLossyPub
    }

    internal func send(userPacket: Livekit_UserPacket,
                       reliability: Reliability = .reliable) -> Promise<Void> {

        func ensurePublisherConnected () -> Promise<Void> {

            guard subscriberPrimary else {
                return Promise(())
            }

            guard let publisher = publisher else {
                return Promise(EngineError.state(message: "publisher is nil"))
            }

            if !publisher.isIceConnected, publisher.iceConnectionState != .checking {
                publisherShouldNegotiate()
            }

            return waitForIceConnect(transport: publisher).then {
                // wait for data channel to open
                self.waitForPublisherDataChannelOpen(reliability: reliability)
            }
        }

        return ensurePublisherConnected().then { () -> Void in

            let packet = Livekit_DataPacket.with {
                $0.kind = reliability.toPBType()
                $0.user = userPacket
            }

            let rtcData = try RTCDataBuffer(data: packet.serializedData(), isBinary: true)

            guard let channel = self.publisherDataChannel(for: reliability) else {
                throw InternalError.state(message: "Data channel is nil")
            }

            guard channel.sendData(rtcData) else {
                throw EngineError.webRTC(message: "DataChannel.sendData returned false")
            }
        }
    }
}

// MARK: - Wait extension

extension Engine {

    func waitForPublisherDataChannelOpen(reliability: Reliability, allowCurrentValue: Bool = true) -> Promise<Void> {

        guard let dcPublisher = publisherDataChannel(for: reliability) else {
            return Promise(EngineError.state(message: "publisher data channel is nil"))
        }

        logger.debug("waiting for dataChannel to open for \(reliability)")
        if allowCurrentValue, dcPublisher.readyState == .open {
            logger.debug("dataChannel already open")
            return Promise(())
        }

        return Promise<Void> { resolve, fail in
            // create temporary delegate
            var engineDelegate: EngineDelegateClosures?
            engineDelegate = EngineDelegateClosures(
                onDataChannelStateUpdated: { _, dataChannel, state in
                    if dataChannel == dcPublisher, state == .open {
                        resolve(())
                        engineDelegate = nil
                    }
                }
            )
            self.add(delegate: engineDelegate!)
            // detect signal close while waiting
            var signalDelegate: SignalClientDelegateClosures?
            signalDelegate = SignalClientDelegateClosures(
                didClose: { _, _ in
                    fail(SignalClientError.close(message: "Socket closed while waiting for ice-connect"))
                    signalDelegate = nil
                }
            )
            self.signalClient.add(delegate: signalDelegate!)
        }
        // convert to timed-promise
        .timeout(10)
    }

    func waitForIceConnect(transport: Transport?, allowCurrentValue: Bool = true) -> Promise<Void> {

        guard let transport = transport else {
            return Promise(EngineError.state(message: "transport is nil"))
        }

        logger.debug("waiting for iceConnect on \(transport)")
        if allowCurrentValue, transport.isIceConnected {
            logger.debug("iceConnect already connected")
            return Promise(())
        }

        return Promise<Void> { resolve, fail in
            // create temporary delegate
            var transportDelegate: TransportDelegateClosures?
            transportDelegate = TransportDelegateClosures(
                onIceStateUpdated: { target, iceState in
                    if transport == target, iceState.isConnected {
                        resolve(())
                        transportDelegate = nil
                    }
                }
            )
            transport.add(delegate: transportDelegate!)
            // detect signal close while waiting
            var signalDelegate: SignalClientDelegateClosures?
            signalDelegate = SignalClientDelegateClosures(
                didClose: { _, _ in
                    fail(SignalClientError.close(message: "Socket closed while waiting for ice-connect"))
                    signalDelegate = nil
                }
            )
            self.signalClient.add(delegate: signalDelegate!)
        }
        // convert to timed-promise
        .timeout(10)
    }

    func waitForPublishTrack(cid: String) -> Promise<Livekit_TrackInfo> {

        return Promise<Livekit_TrackInfo> { resolve, fail in
            // create temporary delegate
            var delegate: SignalClientDelegateClosures?
            delegate = SignalClientDelegateClosures(
                // This promise we be considered failed if signal disconnects while waiting.
                // still it will attempt to re-connect.
                didClose: { _, _ in
                    fail(SignalClientError.close(message: "Socket closed while waiting for publish track"))
                    delegate = nil
                },
                didPublishLocalTrack: { _, response in
                    logger.debug("[SignalClientDelegateClosures] didPublishLocalTrack")
                    if response.cid == cid {
                        // complete when track info received
                        resolve(response.track)
                        delegate = nil
                    }
                }
            )
            self.signalClient.add(delegate: delegate!)
        }
        // convert to timed-promise
        .timeout(10)
    }
}

extension Engine: SignalClientDelegate {

    func configureTransports(joinResponse: Livekit_JoinResponse) {

        guard subscriber == nil, publisher == nil else {
            logger.debug("transports already configured")
            return
        }

        logger.debug("configuring transports...")

        // protocol v3
        subscriberPrimary = joinResponse.subscriberPrimary

        // create publisher and subscribers
        let connectOptions = room.connectOptions ?? ConnectOptions()

        // update iceServers from joinResponse
        connectOptions.rtcConfiguration.update(iceServers: joinResponse.iceServers)

        do {
            subscriber = try Transport(config: connectOptions.rtcConfiguration,
                                       target: .subscriber,
                                       primary: subscriberPrimary,
                                       delegate: self)

            publisher = try Transport(config: connectOptions.rtcConfiguration,
                                      target: .publisher,
                                      primary: !subscriberPrimary,
                                      delegate: self)

            publisher?.onOffer = { offer in
                logger.debug("publisher onOffer")
                self.signalClient.sendOffer(offer: offer)
            }

            // data over pub channel for backwards compatibility
            let reliableConfig = RTCDataChannelConfiguration()
            reliableConfig.isOrdered = true
            dcReliablePub = publisher?.dataChannel(for: RTCDataChannel.labels.reliable,
                                                   configuration: reliableConfig,
                                                   delegate: self)

            let lossyConfig = RTCDataChannelConfiguration()
            lossyConfig.isOrdered = true
            lossyConfig.maxRetransmits = 0
            dcLossyPub = publisher?.dataChannel(for: RTCDataChannel.labels.lossy,
                                                configuration: lossyConfig,
                                                delegate: self)

        } catch {
            //
        }

        if !subscriberPrimary {
            // lazy negotiation for protocol v3+
            publisherShouldNegotiate()
        }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) {
        notify { $0.engine(self, didUpdateSignal: speakers) }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) {
        notify { $0.engine(self, didUpdate: connectionQuality)}
    }

    func signalClient(_ signalClient: SignalClient, didConnect isReconnect: Bool) {
        //
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) {
        notify { $0.engine(self, didReceive: joinResponse) }
    }

    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) {
        let transport = target == .subscriber ? subscriber : publisher
        transport?.addIceCandidate(iceCandidate)
    }

    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription) {

        guard let publisher = self.publisher else {
            logger.warning("signalClient didReceiveAnswer but publisher is nil")
            return
        }

        logger.debug("handling server answer...")
        publisher.setRemoteDescription(answer)
    }

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) {

        guard let subscriber = self.subscriber else {
            logger.warning("signalClient didReceiveOffer but subscriber is nil")
            return
        }

        logger.debug("handling server offer...")
        subscriber.setRemoteDescription(offer).then {
            subscriber.createAnswer()
        }.then { answer in
            subscriber.setLocalDescription(answer)
        }.then { answer in
            self.signalClient.sendAnswer(answer: answer)
        }
    }

    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) {
        logger.debug("received track published confirmation from server for: \(localTrack.track.sid)")
    }

    func signalClientDidLeave(_ signaClient: SignalClient) {
        disconnect()
    }

    func signalClient(_ signalClient: SignalClient, didClose code: URLSessionWebSocketTask.CloseCode) {
        logger.debug("signal connection closed with code: \(code)")
        reconnect()
    }

    func signalClient(_ signalClient: SignalClient, didFailConnect error: Error) {
        logger.debug("signal connection error: \(error)")
        notify { $0.engine(self, didFailConnection: error) }
    }

    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) {
        notify { $0.engine(self, didUpdateRemoteMute: trackSid, muted: muted) }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) {
        notify { $0.engine(self, didUpdate: participants) }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) {
        notify { $0.engine(self, didUpdate: trackStates) }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {
        notify { $0.engine(self, didUpdate: trackSid, subscribedQualities: subscribedQualities) }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) {
        notify { $0.engine(self, didUpdate: subscriptionPermission) }
    }
}

extension Engine: RTCDataChannelDelegate {

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        notify { $0.engine(self, didUpdate: dataChannel, state: dataChannel.readyState) }
    }

    func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {

        guard let dataPacket = try? Livekit_DataPacket(contiguousBytes: buffer.data) else {
            logger.error("could not decode data message")
            return
        }

        switch dataPacket.value {
        case .speaker(let update):
            notify { $0.engine(self, didUpdateEngine: update.speakers) }
        case .user(let userPacket):
            notify { $0.engine(self, didReceive: userPacket) }
        default: return
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
            if iceState == .failed {
                reconnect()
            }
        }
    }

    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        logger.debug("[PCTransportDelegate] did add track")
        if transport.target == .subscriber {
            notify { $0.engine(self, didAdd: track, streams: streams) }
        }
    }

    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {
        logger.debug("[PCTransportDelegate] did add track] did open datachannel")
        if subscriberPrimary, transport.target == .subscriber {
            onReceived(dataChannel: dataChannel)
        }
    }

    func transportShouldNegotiate(_ transport: Transport) {}
}

// MARK: Engine - Factory methods

extension Engine {

    // forbid direct access
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        #if LK_USING_CUSTOM_WEBRTC_BUILD
        let simulcastFactory = RTCVideoEncoderFactorySimulcast(primary: encoderFactory,
                                                               fallback: encoderFactory)
        return RTCPeerConnectionFactory(encoderFactory: simulcastFactory,
                                        decoderFactory: decoderFactory)
        #else
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory,
                                        decoderFactory: decoderFactory)
        #endif
    }()

    internal static func createPeerConnection(_ configuration: RTCConfiguration,
                                              constraints: RTCMediaConstraints) -> RTCPeerConnection? {
        DispatchQueue.webRTC.sync { factory.peerConnection(with: configuration,
                                                           constraints: constraints,
                                                           delegate: nil) }
    }

    internal static func createVideoSource(forScreenShare: Bool) -> RTCVideoSource {
        #if LK_USING_CUSTOM_WEBRTC_BUILD
        DispatchQueue.webRTC.sync { factory.videoSource() }
        #else
        DispatchQueue.webRTC.sync { factory.videoSource(forScreenCast: forScreenShare) }
        #endif
    }

    internal static func createVideoTrack(source: RTCVideoSource) -> RTCVideoTrack {
        DispatchQueue.webRTC.sync { factory.videoTrack(with: source,
                                                       trackId: UUID().uuidString) }
    }

    internal static func createAudioSource(_ constraints: RTCMediaConstraints?) -> RTCAudioSource {
        DispatchQueue.webRTC.sync { factory.audioSource(with: constraints) }
    }

    internal static func createAudioTrack(source: RTCAudioSource) -> RTCAudioTrack {
        DispatchQueue.webRTC.sync { factory.audioTrack(with: source,
                                                       trackId: UUID().uuidString) }
    }
}
