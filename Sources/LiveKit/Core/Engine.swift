import Foundation
import WebRTC
import Promises

internal class Engine: MulticastDelegate<EngineDelegate> {

    internal let signalClient: SignalClient

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
    internal var connectOptions: ConnectOptions?

    public private(set) var connectionState: ConnectionState = .disconnected(reason: .sdk) {
        // automatically notify changes
        didSet {
            guard oldValue != connectionState else { return }
            log("\(oldValue) -> \(self.connectionState)")
            notify { $0.engine(self, didUpdate: self.connectionState, oldState: oldValue) }
        }
    }

    public init(signalClient: SignalClient = SignalClient()) {

        self.signalClient = signalClient
        super.init()

        // Self
        signalClient.add(delegate: self)
        log()
    }

    deinit {
        log()
        signalClient.remove(delegate: self)
    }

    // Resets state of transports
    @discardableResult
    internal func cleanUpRTC() -> Promise<Void> {

        func closeAllDataChannels() -> Promise<Void> {

            let promises = [dcReliablePub, dcLossyPub, dcReliableSub, dcLossySub]
                .compactMap { $0 }
                .map { dc in Promise<Void>(on: .webRTC) { dc.close() } }

            return all(on: .sdk, promises).then(on: .sdk) { (_) -> Void in
                self.dcReliablePub = nil
                self.dcLossyPub = nil
                self.dcReliableSub = nil
                self.dcLossySub = nil
            }
        }

        func closeAllTransports() -> Promise<Void> {

            let promises = [publisher, subscriber]
                .compactMap { $0 }
                .map { $0.close() }

            return all(on: .sdk, promises).then(on: .sdk) { (_) -> Void in
                self.publisher = nil
                self.subscriber = nil
            }
        }

        return closeAllDataChannels().then(on: .sdk) {
            closeAllTransports()
        }
    }

    // Resets state of Engine
    @discardableResult
    internal func cleanUp(reason: DisconnectReason) -> Promise<Void> {

        log("reason: \(reason)")

        url = nil
        token = nil

        connectionState = .disconnected(reason: reason)
        signalClient.cleanUp(reason: reason)

        return cleanUpRTC()
    }

    // Connect sequence only, doesn't update internal state
    internal func fullConnectSequence(_ url: String,
                                      _ token: String) -> Promise<Void> {

        let joinPromises = signalClient.waitForJoinResponse()

        return joinPromises.listen.then(on: .sdk) {
            self.signalClient.connect(url,
                                      token,
                                      connectOptions: self.connectOptions)
        }.then(on: .sdk) {
            joinPromises.wait
        }.then(on: .sdk) { jr in
            self.configureTransports(joinResponse: jr)
        }.then(on: .sdk) {
            self.waitFor(transport: self.primary, state: .connected).wait
        }
    }

    // Connect sequence, resets existing state
    public func connect(_ url: String,
                        _ token: String) -> Promise<Void> {

        return cleanUp(reason: .sdk).then(on: .sdk) {
            self.connectionState = .connecting(.normal)
        }.then(on: .sdk) {
            self.fullConnectSequence(url, token)
        }.then(on: .sdk) {
            // connect sequence successful
            self.log("Connect sequence completed")

            // update internal vars (only if connect succeeded)
            self.url = url
            self.token = token
            self.connectionState = .connected(.normal)

        }.catch(on: .sdk) { error in
            self.cleanUp(reason: .network(error: error))
        }
    }

    @discardableResult
    private func startReconnect() -> Promise<Void> {

        if connectionState.isReconnecting {
            log("Already reconnecting", .warning)
            return Promise(EngineError.state(message: "Already reconnecting"))
        }

        guard case .connected = connectionState else {
            log("Must be called with connected state", .warning)
            return Promise(EngineError.state(message: "Must be called with connected state"))
        }

        guard let url = url, let token = token else {
            log("url or token is nil", . warning)
            return Promise(EngineError.state(message: "url or token is nil"))
        }

        guard subscriber != nil, publisher != nil else {
            log("Publisher or Subscriber is nil", .warning)
            return Promise(EngineError.state(message: "Publisher or Subscriber is nil"))
        }

        // Checks if the re-connection sequence should continue
        func checkShouldContinue() -> Promise<Void> {
            // Check if still reconnecting state in case user already disconnected
            guard self.connectionState.isReconnecting else {
                return Promise(EngineError.state(message: "Reconnection has been aborted"))
            }
            // Continune the sequence
            return Promise(())
        }

        // "quick" re-connection sequence
        func quickReconnectSequence() -> Promise<Void> {

            log("Starting QUICK reconnect sequence...")
            // return Promise(EngineError.state(message: "DEBUG"))

            return checkShouldContinue().then(on: .sdk) {
                self.signalClient.connect(url,
                                          token,
                                          connectOptions: self.connectOptions,
                                          connectMode: .reconnect(.quick))
            }.then(on: .sdk) {
                checkShouldContinue()
            }.then(on: .sdk) {
                // Wait for primary transport to connect (if not already)
                self.waitFor(transport: self.primary, state: .connected).wait
            }.then(on: .sdk) {
                checkShouldContinue()
            }.then(on: .sdk) { () -> Promise<Void> in

                self.subscriber?.restartingIce = true

                // only if published, continue...
                guard let publisher = self.publisher, self.hasPublished else {
                    return Promise(())
                }

                return publisher.createAndSendOffer(iceRestart: true).then(on: .sdk) {
                    self.waitFor(transport: publisher, state: .connected).wait
                }
            }
        }

        // "full" re-connection sequence
        // as a last resort, try to do a clean re-connection and re-publish existing tracks
        func fullReconnectSequence() -> Promise<Void> {
            log("Starting FULL reconnect sequence...")

            return checkShouldContinue().then(on: .sdk) {
                self.cleanUpRTC()
            }.then(on: .sdk) { () -> Promise<Void> in

                guard let url = self.url,
                      let token = self.token else {
                    throw EngineError.state(message: "url or token is nil")
                }

                return self.fullConnectSequence(url, token)
            }
        }

        connectionState = .connecting(.reconnect(.quick))

        return retry(on: .sdk,
                     attempts: 3,
                     delay: .quickReconnectDelay,
                     condition: { triesLeft, _ in
                        self.log("Re-connecting in \(TimeInterval.quickReconnectDelay)seconds, \(triesLeft) tries left...")
                        // only retry if still reconnecting state (not disconnected)
                        return self.connectionState.isReconnecting
                     }) {
            // try quick re-connect
            quickReconnectSequence()
        }.recover(on: .sdk) { (_) -> Promise<Void> in
            // try full re-connect (only if quick re-connect failed)
            self.connectionState = .connecting(.reconnect(.full))
            return fullReconnectSequence()
        }.then(on: .sdk) {
            // re-connect sequence successful
            self.log("Re-connect sequence completed")
            let previousMode = self.connectionState.reconnectingWithMode
            self.connectionState = .connected(.reconnect(previousMode ?? .quick))
        }.catch(on: .sdk) { _ in
            self.log("Re-connect sequence failed")
            // finally disconnect if all attempts fail
            self.cleanUp(reason: .network())
        }
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
                         _ populator: @escaping (inout Livekit_AddTrackRequest) -> Void) -> Promise<Livekit_TrackInfo> {

        // TODO: Check if cid already published

        let promises = waitFor(publishLocalTrackWith: cid)

        return promises.listen.then(on: .sdk) {
            self.signalClient.sendAddTrack(cid: cid,
                                           name: name,
                                           type: kind,
                                           source: source, populator)
        }.then(on: .sdk) {
            return promises.wait
        }
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

            let waitTransport = waitFor(transport: publisher, state: .connected)
            let waitDC = waitForPublisherDataChannelOpen(reliability: reliability)
            let listenBoth = all(on: .sdk, [waitTransport.listen, waitDC.listen])

            return listenBoth.then(on: .sdk) { _ in
                waitTransport.wait
            }.then(on: .sdk) {
                waitDC.wait
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

// MARK: - Wait extensions

// A tuple of Promises,
// listen: resolves when started listening
// wait: resolves when wait is complete or rejects when timeout
typealias WaitPromises<T> = (listen: Promise<Void>, wait: Promise<T>)

extension Engine {

    func waitForPublisherDataChannelOpen(reliability: Reliability, allowCurrentValue: Bool = true) -> WaitPromises<Void> {

        let listen = Promise<Void>(())
        let wait = Promise<Void>(on: .sdk) { resolve, fail in

            guard let dcPublisher = self.publisherDataChannel(for: reliability) else {
                fail(EngineError.state(message: "publisher data channel is nil"))
                listen.fulfill(())
                return
            }

            if allowCurrentValue, dcPublisher.readyState == .open {
                self.log("dataChannel already open")
                resolve(())
                listen.fulfill(())
                return
            }

            // create temporary delegate
            var engineDelegate: EngineDelegateClosures?
            engineDelegate = EngineDelegateClosures(
                didUpdateDataChannelState: { _, dataChannel, state in
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
                didUpdateConnectionState: { _, state in
                    if case .disconnected = state {
                        fail(SignalClientError.close(message: "Socket closed while waiting for ice-connect"))
                        signalDelegate = nil
                    }
                    return true
                }
            )
            self.signalClient.add(delegate: signalDelegate!)
            listen.fulfill(())
        }
        // convert to timed-promise
        .timeout(.defaultConnect)

        return (listen, wait)
    }

    func waitFor(transport: Transport?,
                 state: RTCPeerConnectionState,
                 allowCurrentValue: Bool = true) -> WaitPromises<Void> {

        let listen = Promise<Void>.pending()
        let wait = Promise<Void>(on: .sdk) { resolve, fail in

            guard let transport = transport else {
                fail(EngineError.state(message: "transport is nil"))
                listen.fulfill(())
                return
            }

            if allowCurrentValue, transport.connectionState == state {
                self.log("\(transport) already connected")
                resolve(())
                listen.fulfill(())
                return
            }

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
                didUpdateConnectionState: { _, state in
                    if case .disconnected = state {
                        fail(SignalClientError.close(message: "Socket closed while waiting for ice-connect"))
                        signalDelegate = nil
                    }
                    return true
                }
            )
            self.signalClient.add(delegate: signalDelegate!)
            listen.fulfill(())
        }
        // convert to timed-promise
        .timeout(.defaultConnect)

        return (listen, wait)
    }

    func waitFor(publishLocalTrackWith cid: String) -> WaitPromises<Livekit_TrackInfo> {

        let listen = Promise<Void>.pending()
        let wait = Promise<Livekit_TrackInfo>(on: .sdk) { resolve, fail in
            // create temporary delegate
            var signalDelegate: SignalClientDelegateClosures?
            signalDelegate = SignalClientDelegateClosures(
                // This promise we be considered failed if signal disconnects while waiting.
                // still it will attempt to re-connect.
                didUpdateConnectionState: { _, state in
                    if case .disconnected = state {
                        fail(SignalClientError.close(message: "Socket closed while waiting for ice-connect"))
                        signalDelegate = nil
                    }
                    return true
                },
                didPublishLocalTrack: { _, response in
                    self.log("didPublishLocalTrack", type: SignalClientDelegateClosures.self)
                    if response.cid == cid {
                        // complete when track info received
                        resolve(response.track)
                        signalDelegate = nil
                    }
                    return true
                }
            )
            self.signalClient.add(delegate: signalDelegate!)
            listen.fulfill(())
        }
        // convert to timed-promise
        .timeout(.defaultPublish)

        return (listen, wait)
    }
}

// MARK: - SignalClientDelegate

extension Engine: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didUpdate connectionState: ConnectionState) -> Bool {
        log()
        // Attempt re-connect if disconnected(reason: network)
        if case .disconnected(let reason) = connectionState,
           case .network = reason {
            startReconnect()
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool) -> Bool {
        log()

        // Server indicates it's not recoverable
        if !canReconnect {
            cleanUp(reason: .network())
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) -> Bool {
        let transport = target == .subscriber ? subscriber : publisher
        transport?.addIceCandidate(iceCandidate)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription) -> Bool {

        guard let publisher = self.publisher else {
            log("Publisher is nil", .warning)
            return true
        }

        publisher.setRemoteDescription(answer)

        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) -> Bool {

        guard let subscriber = self.subscriber else {
            log("Subscriber is nil", .error)
            return true
        }

        log()

        subscriber.setRemoteDescription(offer).then(on: .sdk) {
            subscriber.createAnswer()
        }.then(on: .sdk) { answer in
            subscriber.setLocalDescription(answer)
        }.then(on: .sdk) { answer in
            self.signalClient.sendAnswer(answer: answer)
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate token: String) -> Bool {
        self.token = token
        return true
    }
}

// MARK: - RTCDataChannelDelegate

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
            notify { $0.engine(self, didUpdate: update.speakers) }
        case .user(let userPacket):
            notify { $0.engine(self, didReceive: userPacket) }
        default: return
        }
    }
}

// MARK: - TransportDelegate

extension Engine: TransportDelegate {

    func transport(_ transport: Transport, didUpdate state: RTCPeerConnectionState) {
        log("target: \(transport.target), state: \(state)")

        // Attempt re-connect if primary transport failed
        if transport.primary, state == .failed {
            startReconnect()
        }
    }

    private func configureTransports(joinResponse: Livekit_JoinResponse) -> Promise<Void> {

        Promise<Void> { () -> Void in

            self.log("configuring transports...")

            guard self.subscriber == nil, self.publisher == nil else {
                self.log("transports already configured")
                return
            }

            // protocol v3
            self.subscriberPrimary = joinResponse.subscriberPrimary

            // create publisher and subscribers
            let connectOptions = self.connectOptions ?? ConnectOptions()

            // update iceServers from joinResponse
            connectOptions.rtcConfiguration.update(iceServers: joinResponse.iceServers)

            self.subscriber = try Transport(config: connectOptions.rtcConfiguration,
                                            target: .subscriber,
                                            primary: self.subscriberPrimary,
                                            delegate: self)

            self.publisher = try Transport(config: connectOptions.rtcConfiguration,
                                           target: .publisher,
                                           primary: !self.subscriberPrimary,
                                           delegate: self)

            self.publisher?.onOffer = { offer in
                self.log("publisher onOffer")
                return self.signalClient.sendOffer(offer: offer)
            }

            // data over pub channel for backwards compatibility
            self.dcReliablePub = self.publisher?.dataChannel(for: RTCDataChannel.labels.reliable,
                                                             configuration: Engine.createDataChannelConfiguration(),
                                                             delegate: self)

            self.dcLossyPub = self.publisher?.dataChannel(for: RTCDataChannel.labels.lossy,
                                                          configuration: Engine.createDataChannelConfiguration(maxRetransmits: 0),
                                                          delegate: self)

            if !self.subscriberPrimary {
                // lazy negotiation for protocol v3+
                self.publisherShouldNegotiate()
            }
        }
    }

    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate) {
        log("didGenerate iceCandidate")
        signalClient.sendCandidate(candidate: iceCandidate,
                                   target: transport.target).catch { error in
                                    self.log("Failed to send candidate, error: \(error)", .error)
                                   }
    }

    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        log("did add track")
        if transport.target == .subscriber {
            notify { $0.engine(self, didAdd: track, streams: streams) }
        }
    }

    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {
        log("Did open dataChannel label: \(dataChannel.label)")
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
