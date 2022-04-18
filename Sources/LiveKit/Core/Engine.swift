/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import WebRTC
import Promises
import Network

internal class Engine: MulticastDelegate<EngineDelegate> {

    public let signalClient = SignalClient()

    public var url: String? { state.url }
    public var token: String? { state.token }
    public var connectionState: ConnectionState { state.connectionState }
    public var connectStopwatch: Stopwatch { state.connectStopwatch }

    // private(set) var hasPublished: Bool = false
    private(set) var publisher: Transport?
    private(set) var subscriber: Transport?

    private(set) var connectOptions: ConnectOptions
    private(set) var roomOptions: RoomOptions

    private var subscriberPrimary: Bool = false
    private var primary: Transport? {
        subscriberPrimary ? subscriber : publisher
    }

    private var dcReliablePub: RTCDataChannel?
    private var dcLossyPub: RTCDataChannel?
    private var dcReliableSub: RTCDataChannel?
    private var dcLossySub: RTCDataChannel?

    internal struct State {
        var url: String?
        var token: String?
        var connectionState: ConnectionState = .disconnected(reason: .sdk)
        var connectStopwatch = Stopwatch(label: "connect")
        var hasPublished: Bool = false
        var primaryTransportConnectedCompleter = Completer<Void>()
        var publisherTransportConnectedCompleter = Completer<Void>()
        var publisherReliableDCOpenCompleter = Completer<Void>()
        var publisherLossyDCOpenCompleter = Completer<Void>()
    }

    private var state = StateSync(State())

    init(connectOptions: ConnectOptions,
         roomOptions: RoomOptions) {

        self.connectOptions = connectOptions
        self.roomOptions = roomOptions
        super.init()
        self.state.onMutate = { [weak self] oldState, newState in
            guard let self = self else { return }

            if oldState.connectionState != newState.connectionState {
                self.log("\(oldState.connectionState) -> \(newState.connectionState)")
                self.notifyAsync { $0.engine(self, didUpdate: newState.connectionState, oldValue: oldState.connectionState) }
            }
        }

        signalClient.add(delegate: self)
        ConnectivityListener.shared.add(delegate: self)
        log()
    }

    deinit {
        log()
    }

    // Connect sequence, resets existing state
    func connect(_ url: String,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil,
                 roomOptions: RoomOptions? = nil) -> Promise<Void> {

        // update options if specified
        self.connectOptions = connectOptions ?? self.connectOptions
        self.roomOptions = roomOptions ?? self.roomOptions

        return cleanUp(reason: .sdk).then(on: .sdk) {
            self.state.mutate { $0.connectionState = .connecting(.normal) }
        }.then(on: .sdk) {
            self.fullConnectSequence(url, token)
        }.then(on: .sdk) {
            // connect sequence successful
            self.log("Connect sequence completed")

            // update internal vars (only if connect succeeded)
            self.state.mutate {
                $0.url = url
                $0.token = token
                $0.connectionState = .connected(.normal)
            }

        }.catch(on: .sdk) { error in
            self.cleanUp(reason: .network(error: error))
        }
    }

    // Resets state of Engine
    @discardableResult
    func cleanUp(reason: DisconnectReason) -> Promise<Void> {

        log("reason: \(reason)")

        // reset state
        state.mutate {
            $0.primaryTransportConnectedCompleter.reset()
            $0.publisherTransportConnectedCompleter.reset()
            $0.publisherReliableDCOpenCompleter.reset()
            $0.publisherLossyDCOpenCompleter.reset()
            $0 = State(connectionState: .disconnected(reason: reason))
        }

        signalClient.cleanUp(reason: reason)

        return cleanUpRTC()
    }

    // sends addTrack request and waits for the trackInfo
    func sendAndWaitAddTrackRequest<R>(cid: String,
                                       name: String,
                                       kind: Livekit_TrackType,
                                       source: Livekit_TrackSource = .unknown,
                                       _ populator: @escaping SignalClient.AddTrackRequestPopulator<R>) -> Promise<(result: R, trackInfo: Livekit_TrackInfo)> {

        // TODO: Check if cid already published

        //        let completer =

        return signalClient.sendAddTrack(cid: cid,
                                         name: name,
                                         type: kind,
                                         source: source, populator).then(on: .sdk) { populateResult in
                                            let promise = self.signalClient.prepareCompleter(forAddTrackRequest: cid)
                                            //            let promise = Promise<Livekit_TrackInfo>.pending()
                                            return promise.then(on: .sdk) { (result: populateResult, trackInfo: $0) }
                                         }
    }

    func publisherShouldNegotiate() {

        guard let publisher = publisher else {
            log("negotiate() publisher is nil")
            return
        }

        state.mutate { $0.hasPublished = true }

        publisher.negotiate()
    }

    func send(userPacket: Livekit_UserPacket,
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

            let p1 = state.mutate {
                $0.publisherTransportConnectedCompleter.wait(on: .sdk, .defaultTransportState, throw: { TransportError.timedOut(message: "publisher didn't connect") })
            }

            let p2 = state.mutate { state -> Promise<Void> in
                var completer = reliability == .reliable ? state.publisherReliableDCOpenCompleter : state.publisherLossyDCOpenCompleter
                return completer.wait(on: .sdk, .defaultPublisherDataChannelOpen, throw: { TransportError.timedOut(message: "publisher dc didn't open") })
            }

            return [p1, p2].all(on: .sdk)
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

// MARK: - Private

private extension Engine {

    func publisherDataChannel(for reliability: Reliability) -> RTCDataChannel? {
        reliability == .reliable ? dcReliablePub : dcLossyPub
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

    // Resets state of transports
    @discardableResult
    func cleanUpRTC() -> Promise<Void> {

        func closeAllDataChannels() -> Promise<Void> {

            let promises = [dcReliablePub, dcLossyPub, dcReliableSub, dcLossySub]
                .compactMap { $0 }
                .map { dc in Promise<Void>(on: .webRTC) { dc.close() } }

            return promises.all(on: .sdk).then(on: .sdk) {
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

            return promises.all(on: .sdk).then(on: .sdk) {
                self.publisher = nil
                self.subscriber = nil
                self.state.mutate { $0.hasPublished = false }
            }
        }

        return closeAllDataChannels()
            .recover(on: .sdk) { self.log("Failed to close data channels, error: \($0)") }
            .then(on: .sdk) {
                closeAllTransports()
            }
    }

    // Connect sequence only, doesn't update internal state
    func fullConnectSequence(_ url: String,
                             _ token: String) -> Promise<Void> {

        return self.signalClient.connect(url,
                                         token,
                                         connectOptions: self.connectOptions)
            .then(on: .sdk) {
                // wait for joinResponse
                self.signalClient.state.mutate { $0.joinResponseCompleter.wait(on: .sdk,
                                                                               .defaultJoinResponse,
                                                                               throw: { SignalClientError.timedOut(message: "failed to receive join response") }) }
            }.then(on: .sdk) { _ in
                self.state.mutate { $0.connectStopwatch.split(label: "signal") }
            }.then(on: .sdk) { jr in
                self.configureTransports(joinResponse: jr)
            }.then(on: .sdk) {
                self.signalClient.resumeResponseQueue()
            }.then(on: .sdk) {
                self.state.mutate { $0.primaryTransportConnectedCompleter.wait(on: .sdk,
                                                                               .defaultTransportState,
                                                                               throw: { TransportError.timedOut(message: "primary transport didn't connect") }) }
            }.then(on: .sdk) {
                self.state.mutate { $0.connectStopwatch.split(label: "engine") }
                self.log("\(self.connectStopwatch)")
            }
    }

    @discardableResult
    func startReconnect() -> Promise<Void> {

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
                self.state.mutate { $0.primaryTransportConnectedCompleter.wait(on: .sdk,
                                                                               .defaultTransportState,
                                                                               throw: { TransportError.timedOut(message: "primary transport didn't connect") }) }
            }.then(on: .sdk) {
                checkShouldContinue()
            }.then(on: .sdk) { () -> Promise<Void> in

                self.subscriber?.restartingIce = true

                // only if published, continue...
                guard let publisher = self.publisher, self.state.hasPublished else {
                    return Promise(())
                }

                return publisher.createAndSendOffer(iceRestart: true).then(on: .sdk) {
                    self.state.mutate { $0.publisherTransportConnectedCompleter.wait(on: .sdk,
                                                                                     .defaultTransportState,
                                                                                     throw: { TransportError.timedOut(message: "publisher transport didn't connect") }) }
                }

            }.then(on: .sdk) {
                // always check if there are queued requests
                self.signalClient.sendQueuedRequests()
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

        state.mutate { $0.connectionState = .connecting(.reconnect(.quick)) }

        return retry(on: .sdk,
                     attempts: 3,
                     delay: .defaultQuickReconnectRetry,
                     condition: { triesLeft, _ in
                        self.log("Re-connecting in \(TimeInterval.defaultQuickReconnectRetry)seconds, \(triesLeft) tries left...")
                        // only retry if still reconnecting state (not disconnected)
                        return self.connectionState.isReconnecting
                     }, _: {
                        // try quick re-connect
                        quickReconnectSequence()
                     }).recover(on: .sdk) { (_) -> Promise<Void> in
                        // try full re-connect (only if quick re-connect failed)
                        self.state.mutate { $0.connectionState = .connecting(.reconnect(.full)) }
                        return fullReconnectSequence()
                     }.then(on: .sdk) {
                        // re-connect sequence successful
                        self.log("Re-connect sequence completed")
                        let previousMode = self.connectionState.reconnectingWithMode
                        self.state.mutate { $0.connectionState = .connected(.reconnect(previousMode ?? .quick)) }
                     }.catch(on: .sdk) { _ in
                        self.log("Re-connect sequence failed")
                        // finally disconnect if all attempts fail
                        self.cleanUp(reason: .network())
                     }
    }

}

// MARK: - Session Migration

internal extension Engine {

    func dataChannelInfo() -> [Livekit_DataChannelInfo] {

        [publisherDataChannel(for: .lossy), publisherDataChannel(for: .reliable)]
            .compactMap { $0 }
            .map { $0.toLKInfoType() }
    }
}

// MARK: - SignalClientDelegate

extension Engine: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didUpdate connectionState: ConnectionState, oldValue: ConnectionState) -> Bool {
        log()

        guard !connectionState.isEqual(to: oldValue, includingAssociatedValues: false) else {
            log("Skipping same conectionState")
            return true
        }

        // Attempt re-connect if disconnected(reason: network)
        if case .disconnected(let reason) = connectionState,
           case .network = reason {
            startReconnect()
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool) -> Bool {
        log("canReconnect: \(canReconnect)")

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

        // update token
        state.mutate { $0.token = token }

        return true
    }
}

// MARK: - RTCDataChannelDelegate

extension Engine: RTCDataChannelDelegate {

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        // notify new state
        notify { $0.engine(self, didUpdate: dataChannel, state: dataChannel.readyState) }

        state.mutate {
            if dataChannel == dcReliablePub {
                $0.publisherReliableDCOpenCompleter.set(value: dataChannel.readyState == .open ? () : nil)
            } else if dataChannel == dcLossyPub {
                $0.publisherLossyDCOpenCompleter.set(value: dataChannel.readyState == .open ? () : nil)
            }
        }

        self.log("dataChannel.\(dataChannel.label) didChangeState : \(dataChannel.channelId)")
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

    func transport(_ transport: Transport, didGenerate stats: [TrackStats], target: Livekit_SignalTarget) {
        // relay to Room
        notify { $0.engine(self, didGenerate: stats, target: target) }
    }

    func transport(_ transport: Transport, didUpdate pcState: RTCPeerConnectionState) {
        log("target: \(transport.target), state: \(state)")

        // primary connected
        if transport.primary {
            state.mutate { $0.primaryTransportConnectedCompleter.set(value: .connected == pcState ? () : nil) }
        }

        // publisher connected
        if case .publisher = transport.target {
            state.mutate { $0.publisherTransportConnectedCompleter.set(value: .connected == pcState ? () : nil) }
        }

        if connectionState.isConnected {
            // Attempt re-connect if primary or publisher transport failed
            if (transport.primary || (state.hasPublished && transport.target == .publisher)) && [.disconnected, .failed].contains(pcState) {
                startReconnect()
            }
        }
    }

    private func configureTransports(joinResponse: Livekit_JoinResponse) -> Promise<Void> {

        Promise<Void>(on: .sdk) { () -> Void in

            self.log("configuring transports...")

            guard self.subscriber == nil, self.publisher == nil else {
                self.log("transports already configured")
                return
            }

            // protocol v3
            self.subscriberPrimary = joinResponse.subscriberPrimary
            self.log("subscriberPrimary: \(joinResponse.subscriberPrimary)")

            // update iceServers from joinResponse
            self.connectOptions.rtcConfiguration.set(iceServers: joinResponse.iceServers)

            self.subscriber = try Transport(config: self.connectOptions.rtcConfiguration,
                                            target: .subscriber,
                                            primary: self.subscriberPrimary,
                                            delegate: self,
                                            reportStats: self.roomOptions.reportStats)

            self.publisher = try Transport(config: self.connectOptions.rtcConfiguration,
                                           target: .publisher,
                                           primary: !self.subscriberPrimary,
                                           delegate: self,
                                           reportStats: self.roomOptions.reportStats)

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

            self.log("dataChannel.\(String(describing: self.dcReliablePub?.label)) : \(String(describing: self.dcReliablePub?.channelId))")
            self.log("dataChannel.\(String(describing: self.dcLossyPub?.label)) : \(String(describing: self.dcLossyPub?.channelId))")

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

    func transport(_ transport: Transport, didRemove track: RTCMediaStreamTrack) {
        if transport.target == .subscriber {
            notify { $0.engine(self, didRemove: track) }
        }
    }

    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {
        log("Did open dataChannel label: \(dataChannel.label)")
        if subscriberPrimary, transport.target == .subscriber {
            onReceived(dataChannel: dataChannel)
        }

        self.log("dataChannel..\(dataChannel.label) : \(dataChannel.channelId)")
    }

    func transportShouldNegotiate(_ transport: Transport) {}
}

// MARK: - ConnectivityListenerDelegate

extension Engine: ConnectivityListenerDelegate {

    func connectivityListener(_: ConnectivityListener, didSwitch path: NWPath) {
        log("didSwitch path: \(path)")

        // network has been switched, e.g. wifi <-> cellular
        if case .connected = connectionState {
            startReconnect()
        }
    }
}

// MARK: Engine - Factory methods

extension Engine {

    // forbid direct access
    private static let factory: RTCPeerConnectionFactory = {
        logger.log("initializing PeerConnectionFactory...", type: Engine.self)
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        #if LK_USING_CUSTOM_WEBRTC_BUILD
        let simulcastFactory = RTCVideoEncoderFactorySimulcast(primary: encoderFactory,
                                                               fallback: encoderFactory)
        let result: RTCPeerConnectionFactory
        result = RTCPeerConnectionFactory(encoderFactory: simulcastFactory,
                                          decoderFactory: decoderFactory)
        #else
        result = RTCPeerConnectionFactory(encoderFactory: encoderFactory,
                                          decoderFactory: decoderFactory)
        #endif
        logger.log("PeerConnectionFactory initialized", type: Engine.self)
        return result
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
