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
            log("\(oldValue) -> \(self.connectionState)")
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
        log()
    }

    deinit {
        log()
        signalClient.remove(delegate: self)
    }

    public func connect(_ url: String,
                        _ token: String) -> Promise<Void> {

        guard connectionState != .connected else {
            log("already connected")
            return Promise(EngineError.state(message: "already connected"))
        }

        // reset internal vars
        self.url = nil
        self.token = nil

        self.connectionState = .connecting(isReconnecting: false)

        return signalClient.connect(url,
                                    token,
                                    connectOptions: room.connectOptions).then(on: .sdk) {
                                        // wait for join response
                                        self.signalClient.waitReceiveJoinResponse()
                                    }.then(on: .sdk) { joinResponse in
                                        // set up peer connections
                                        self.configureTransports(joinResponse: joinResponse)
                                    }.then(on: .sdk) {
                                        // wait for peer connections to connect
                                        self.wait(transport: self.primary, state: .connected)
                                    }.then(on: .sdk) {
                                        // connect sequence successful
                                        self.log("connect sequence completed")

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
            log("reconnect() must be called with connected state")
            return Promise(EngineError.state(message: "reconnect() called with no url or token"))
        }

        guard case .connected = connectionState else {
            log("reconnect() must be called with connected state")
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
                                 reconnect: true).then(on: .sdk) {
                                    self.wait(transport: self.primary, state: .connected)
                                 }.then(on: .sdk) { () -> Promise<Void> in
                                    self.subscriber?.restartingIce = true

                                    // only if published, continue...
                                    guard let publisher = self.publisher, self.hasPublished else {
                                        return Promise(())
                                    }

                                    return publisher.createAndSendOffer(iceRestart: true).then(on: .sdk) {
                                        self.wait(transport: publisher, state: .connected)
                                    }
                                 }
        }

        let delay: TimeInterval = 1
        return retry(attempts: 5, delay: delay) { remainingAttempts, _ in
            self.log("re-connecting in \(delay)second(s), \(remainingAttempts) remaining attempts...")
            // only retry if still reconnecting state (not disconnected)
            return .connecting(isReconnecting: true) == self.connectionState
        } _: {
            // try to re-connect
            reconnectSequence()
        }.then(on: .sdk) {
            // re-connect sequence successful
            self.log("re-connect sequence completed")
            self.connectionState = .connected
        }.catch { _ in
            // finally disconnect if all attempts fail
            self.disconnect()
        }
    }

    public func disconnect() {

        guard .disconnected() != connectionState else {
            log("disconnect() already disconnected", .warning)
            return
        }

        cleanUp()
        connectionState = .disconnected()
        signalClient.close()
    }

    // resets internal vars
    private func cleanUp() {

        url = nil
        token = nil

        publisher?.close()
        publisher = nil

        subscriber?.close()
        subscriber = nil
    }

    private func onReceived(dataChannel: RTCDataChannel) {

        log("Server opened data channel \(dataChannel.label)")

        switch dataChannel.label {
        case RTCDataChannel.labels.reliable:
            dcReliableSub = dataChannel
            dcReliableSub?.delegate = self
        case RTCDataChannel.labels.lossy:
            dcLossySub = dataChannel
            dcLossySub?.delegate = self
        default:
            log("Unknown data channel label \(dataChannel.label)", .warning)
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
            log("negotiate() publisher is nil")
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

            if !publisher.isConnected, publisher.connectionState != .connecting {
                publisherShouldNegotiate()
            }

            return wait(transport: publisher, state: .connected).then(on: .sdk) {
                // wait for data channel to open
                self.waitForPublisherDataChannelOpen(reliability: reliability)
            }
        }

        return ensurePublisherConnected().then(on: .sdk) { () -> Void in

            let packet = Livekit_DataPacket.with {
                $0.kind = reliability.toPBType()
                $0.user = userPacket
            }

            let serializedData = try packet.serializedData()
            let rtcData = Engine.createDataBuffer(data: serializedData)

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

        log("waiting for dataChannel to open for \(reliability)")
        if allowCurrentValue, dcPublisher.readyState == .open {
            log("dataChannel already open")
            return Promise(())
        }

        return Promise<Void>(on: .sdk) { resolve, fail in
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
        .timeout(.defaultConnect)
    }

    func wait(transport: Transport?,
              state: RTCPeerConnectionState,
              allowCurrentValue: Bool = true) -> Promise<Void> {

        guard let transport = transport else {
            return Promise(EngineError.state(message: "transport is nil"))
        }

        log("Waiting for \(transport) to connect...")
        if allowCurrentValue, transport.connectionState == state {
            log("\(transport) already connected")
            return Promise(())
        }

        return Promise<Void>(on: .sdk) { resolve, fail in
            // create temporary delegate
            var transportDelegate: TransportDelegateClosures?
            transportDelegate = TransportDelegateClosures(
                onDidUpdateState: { target, newState in
                    if transport == target, newState == state {
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
        .timeout(.defaultConnect)
    }

    func waitForPublishTrack(cid: String) -> Promise<Livekit_TrackInfo> {

        return Promise<Livekit_TrackInfo>(on: .sdk) { resolve, fail in
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
                    self.log("didPublishLocalTrack", type: SignalClientDelegateClosures.self)
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
        .timeout(.defaultPublish)
    }
}

extension Engine: SignalClientDelegate {

    func configureTransports(joinResponse: Livekit_JoinResponse) {

        guard subscriber == nil, publisher == nil else {
            log("transports already configured")
            return
        }

        log("configuring transports...")

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
                self.log("publisher onOffer")
                self.signalClient.sendOffer(offer: offer)
            }

            // data over pub channel for backwards compatibility
            dcReliablePub = publisher?.dataChannel(for: RTCDataChannel.labels.reliable,
                                                   configuration: Engine.createDataChannelConfiguration(),
                                                   delegate: self)

            dcLossyPub = publisher?.dataChannel(for: RTCDataChannel.labels.lossy,
                                                configuration: Engine.createDataChannelConfiguration(maxRetransmits: 0),
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
            log("signalClient didReceiveAnswer but publisher is nil", .warning)
            return
        }

        log("handling server answer...")
        publisher.setRemoteDescription(answer)
    }

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) {

        guard let subscriber = self.subscriber else {
            log("signalClient didReceiveOffer but subscriber is nil", .warning)
            return
        }

        log("handling server offer...")
        subscriber.setRemoteDescription(offer).then(on: .sdk) {
            subscriber.createAnswer()
        }.then(on: .sdk) { answer in
            subscriber.setLocalDescription(answer)
        }.then(on: .sdk) { answer in
            self.signalClient.sendAnswer(answer: answer)
        }
    }

    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) {
        log("received track published confirmation from server for: \(localTrack.track.sid)")
    }

    func signalClientDidLeave(_ signaClient: SignalClient) {
        disconnect()
    }

    func signalClient(_ signalClient: SignalClient, didClose code: URLSessionWebSocketTask.CloseCode) {
        log("signal connection closed with code: \(code)")
        reconnect()
    }

    func signalClient(_ signalClient: SignalClient, didFailConnect error: Error) {
        log("signal connection error: \(error)")
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
            log("could not decode data message", .error)
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
        log("didGenerate iceCandidate")
        try? signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
    }

    func transport(_ transport: Transport, didUpdate state: RTCPeerConnectionState) {
        log("state: \(state)")
        if transport.primary, state == .failed {
            reconnect()
        }
    }

    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        log("did add track")
        if transport.target == .subscriber {
            notify { $0.engine(self, didAdd: track, streams: streams) }
        }
    }

    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {
        log("did add track] did open datachannel")
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

    internal static func createDataChannelConfiguration(ordered: Bool = true,
                                                        maxRetransmits: Int32 = -1) -> RTCDataChannelConfiguration {
        let result = DispatchQueue.webRTC.sync { RTCDataChannelConfiguration() }
        result.isOrdered = ordered
        result.maxRetransmits = maxRetransmits
        return result
    }

    internal static func createDataBuffer(data: Data) -> RTCDataBuffer {
        DispatchQueue.webRTC.sync { RTCDataBuffer(data: data, isBinary: true) }
    }

    internal static func createIceCandidate(fromJsonString: String) throws -> RTCIceCandidate {
        try DispatchQueue.webRTC.sync { try RTCIceCandidate(fromJsonString: fromJsonString) }
    }

    internal static func createSessionDescription(type: RTCSdpType, sdp: String) -> RTCSessionDescription {
        DispatchQueue.webRTC.sync { RTCSessionDescription(type: type, sdp: sdp) }
    }

    internal static func createVideoCapturer() -> RTCVideoCapturer {
        DispatchQueue.webRTC.sync { RTCVideoCapturer() }
    }

    internal static func createRtpEncodingParameters(rid: String? = nil,
                                                     encoding: VideoEncoding? = nil,
                                                     scaleDown: Double = 1.0,
                                                     active: Bool = true) -> RTCRtpEncodingParameters {

        let result = DispatchQueue.webRTC.sync { RTCRtpEncodingParameters() }

        result.isActive = active
        result.rid = rid
        result.scaleResolutionDownBy = NSNumber(value: scaleDown)

        if let encoding = encoding {
            result.maxFramerate = NSNumber(value: encoding.maxFps)
            result.maxBitrateBps = NSNumber(value: encoding.maxBitrate)
        }

        return result
    }
}
