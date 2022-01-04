import Foundation
import WebRTC
import Promises

class Engine: MulticastDelegate<EngineDelegate> {

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

    private(set) var reliableDC: RTCDataChannel?
    private(set) var lossyDC: RTCDataChannel?
    private(set) var reliableDCSub: RTCDataChannel?
    private(set) var lossyDCSub: RTCDataChannel?

    internal var url: String?
    internal var token: String?

    var connectionState: ConnectionState = .disconnected() {
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

    init(room: Room,
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

    private func onReceived(dataChannel: RTCDataChannel) {

        logger.debug("Server opened data channel \(dataChannel.label)")

        switch dataChannel.label {
        case RTCDataChannel.labels.reliable:
            reliableDCSub = dataChannel
            reliableDCSub?.delegate = self
        case RTCDataChannel.labels.lossy:
            lossyDCSub = dataChannel
            lossyDCSub?.delegate = self
        default:
            logger.warning("Unknown data channel label \(dataChannel.label)")
        }
    }

    func connect(_ url: String,
                 _ token: String) -> Promise<Void> {

        guard connectionState != .connected else {
            logger.debug("already connected")
            return Promise(EngineError.invalidState("already connected"))
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
            return Promise(EngineError.invalidState("reconnect() called with no url or token"))
        }

        guard case .connected = connectionState else {
            logger.debug("reconnect() must be called with connected state")
            return Promise(EngineError.invalidState("reconnect() called with invalid state"))
        }

        guard subscriber != nil, publisher != nil else {
            return Promise(EngineError.invalidState("publisher or subscriber is null"))
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

    func disconnect() {

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

    func addTrack(cid: String,
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

    internal func send(userPacket: Livekit_UserPacket,
                       reliability: DataPublishReliability = .reliable) -> Promise<Void> {

        return ensurePublisherConnected().then { () -> Void in

            let packet = Livekit_DataPacket.with {
                $0.kind = reliability.toLKType()
                $0.user = userPacket
            }

            let rtcData = try RTCDataBuffer(data: packet.serializedData(), isBinary: true)

            guard let channel = packet.kind == .lossy ? self.lossyDC : self.reliableDC else {
                throw InternalError.state("Data channel is nil")
            }

            guard channel.sendData(rtcData) else {
                throw EngineError.webRTC("DataChannel.sendData returned false")
            }
        }
    }

    private func ensurePublisherConnected () -> Promise<Void> {

        guard let publisher = publisher else {
            return Promise(EngineError.invalidState("publisher is nil"))
        }

        guard subscriberPrimary, !publisher.isIceConnected else {
            // aleady connected, no-op
            return Promise(())
        }

        publisherShouldNegotiate()

        return waitForIceConnect(transport: publisher)
    }
}

// MARK: - Wait extension

extension Engine {

    func waitForIceConnect(transport: Transport?, allowCurrentValue: Bool = true) -> Promise<Void> {

        guard let transport = transport else {
            return Promise(EngineError.invalidState("transport is nil"))
        }

        logger.debug("waiting for iceConnect on \(transport)")
        if allowCurrentValue, transport.isIceConnected {
            logger.debug("iceConnect already connected")
            return Promise(())
        }

        return Promise<Void> { fulfill, _ in
            // create temporary delegate
            var delegate: TransportDelegateClosures?
            delegate = TransportDelegateClosures(onIceStateUpdated: { _, iceState in
                if iceState.isConnected {
                    fulfill(())
                    delegate = nil
                }
            })
            transport.add(delegate: delegate!)
        }
        // convert to timed-promise
        .timeout(10)
    }

    func waitForPublishTrack(cid: String) -> Promise<Livekit_TrackInfo> {

        return Promise<Livekit_TrackInfo> { fulfill, _ in
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
                try? self.signalClient.sendOffer(offer: offer)
            }

            // data over pub channel for backwards compatibility
            let reliableConfig = RTCDataChannelConfiguration()
            reliableConfig.isOrdered = true
            reliableDC = publisher?.dataChannel(for: RTCDataChannel.labels.reliable,
                                                configuration: reliableConfig,
                                                delegate: self)

            let lossyConfig = RTCDataChannelConfiguration()
            lossyConfig.isOrdered = true
            lossyConfig.maxRetransmits = 0
            lossyDC = publisher?.dataChannel(for: RTCDataChannel.labels.lossy,
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
            try? self.signalClient.sendAnswer(answer: answer)
        }
    }

    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) {
        logger.debug("received track published confirmation from server for: \(localTrack.track.sid)")
    }

    func signalClientDidLeave(_ signaClient: SignalClient) {
        disconnect()
    }

    func signalClient(_ signalClient: SignalClient, didClose reason: String, code: UInt16) {
        logger.debug("signal connection closed with code: \(code), reason: \(reason)")
        reconnect()
    }

    func signalClient(_ signalClient: SignalClient, didFailConnection error: Error) {
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
