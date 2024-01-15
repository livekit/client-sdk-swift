/*
 * Copyright 2024 LiveKit
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

#if canImport(Network)
    import Network
#endif

@_implementationOnly import WebRTC

class Engine: MulticastDelegate<EngineDelegate> {
    // MARK: - Public

    public typealias ConditionEvalFunc = (_ newState: State, _ oldState: State?) -> Bool

    struct State: Equatable {
        var connectOptions: ConnectOptions
        var url: String?
        var token: String?
        // preferred reconnect mode which will be used only for next attempt
        var nextPreferredReconnectMode: ReconnectMode?
        var reconnectMode: ReconnectMode?
        var connectionState: ConnectionState = .disconnected
        var disconnectError: LiveKitError?
        var connectStopwatch = Stopwatch(label: "connect")
        var hasPublished: Bool = false
    }

    let primaryTransportConnectedCompleter = AsyncCompleter<Void>(label: "Primary transport connect", defaultTimeOut: .defaultTransportState)
    let publisherTransportConnectedCompleter = AsyncCompleter<Void>(label: "Publisher transport connect", defaultTimeOut: .defaultTransportState)

    public var _state: StateSync<State>

    public let signalClient = SignalClient()

    public internal(set) var publisher: Transport?
    public internal(set) var subscriber: Transport?

    // weak ref to Room
    public weak var _room: Room?

    // MARK: - Private

    private struct ConditionalExecutionEntry {
        let executeCondition: ConditionEvalFunc
        let removeCondition: ConditionEvalFunc
        let block: () -> Void
    }

    public internal(set) var subscriberPrimary: Bool = false

    // MARK: - DataChannels

    lazy var subscriberDataChannel: DataChannelPairActor = .init(onDataPacket: { [weak self] dataPacket in
        guard let self else { return }
        switch dataPacket.value {
        case let .speaker(update): self.notify { $0.engine(self, didUpdateSpeakers: update.speakers) }
        case let .user(userPacket): self.notify { $0.engine(self, didReceiveUserPacket: userPacket) }
        default: return
        }
    })

    let publisherDataChannel = DataChannelPairActor()

    private var _blockProcessQueue = DispatchQueue(label: "LiveKitSDK.engine.pendingBlocks",
                                                   qos: .default)

    private var _queuedBlocks = [ConditionalExecutionEntry]()

    init(connectOptions: ConnectOptions) {
        _state = StateSync(State(connectOptions: connectOptions))
        super.init()

        // log sdk & os versions
        log("sdk: \(LiveKit.version), os: \(String(describing: Utils.os()))(\(Utils.osVersionString())), modelId: \(String(describing: Utils.modelIdentifier() ?? "unknown"))")

        signalClient.add(delegate: self)
        ConnectivityListener.shared.add(delegate: self)

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self else { return }

            assert(!(newState.connectionState == .reconnecting && newState.reconnectMode == .none), "reconnectMode should not be .none")

            if (newState.connectionState != oldState.connectionState) || (newState.reconnectMode != oldState.reconnectMode) {
                self.log("connectionState: \(oldState.connectionState) -> \(newState.connectionState), reconnectMode: \(String(describing: newState.reconnectMode))")
            }

            self.notify { $0.engine(self, didMutateState: newState, oldState: oldState) }

            // execution control
            self._blockProcessQueue.async { [weak self] in
                guard let self, !self._queuedBlocks.isEmpty else { return }

                self.log("[execution control] processing pending entries (\(self._queuedBlocks.count))...")

                self._queuedBlocks.removeAll { entry in
                    // return and remove this entry if matches remove condition
                    guard !entry.removeCondition(newState, oldState) else { return true }
                    // return but don't remove this entry if doesn't match execute condition
                    guard entry.executeCondition(newState, oldState) else { return false }

                    self.log("[execution control] condition matching block...")
                    entry.block()
                    // remove this entry
                    return true
                }
            }
        }
    }

    deinit {
        log()
    }

    // Connect sequence, resets existing state
    func connect(_ url: String,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil) async throws
    {
        // update options if specified
        if let connectOptions, connectOptions != _state.connectOptions {
            _state.mutate { $0.connectOptions = connectOptions }
        }

        try await cleanUp()
        try Task.checkCancellation()

        _state.mutate { $0.connectionState = .connecting }

        do {
            try await fullConnectSequence(url, token)

            // Connect sequence successful
            log("Connect sequence completed")

            // Final check if cancelled, don't fire connected events
            try Task.checkCancellation()

            // update internal vars (only if connect succeeded)
            _state.mutate {
                $0.url = url
                $0.token = token
                $0.connectionState = .connected
            }

        } catch {
            try await cleanUp(withError: error)
            // Re-throw error
            throw error
        }
    }

    // cleanUp (reset) both Room & Engine's state
    func cleanUp(withError disconnectError: Error? = nil,
                 isFullReconnect: Bool = false) async throws
    {
        // This should never happen since Engine is owned by Room
        let room = try requireRoom()
        // Call Room's cleanUp
        await room.cleanUp(withError: disconnectError,
                           isFullReconnect: isFullReconnect)
    }

    // Resets state of transports
    func cleanUpRTC() async {
        // Close data channels
        await publisherDataChannel.reset()
        await subscriberDataChannel.reset()

        // Close transports
        await publisher?.close()
        publisher = nil

        await subscriber?.close()
        subscriber = nil

        // Reset publish state
        _state.mutate { $0.hasPublished = false }
    }

    func publisherShouldNegotiate() async throws {
        log()

        let publisher = try requirePublisher()
        publisher.negotiate()
        _state.mutate { $0.hasPublished = true }
    }

    func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket.Kind) async throws {
        func ensurePublisherConnected() async throws {
            guard subscriberPrimary else { return }

            let publisher = try requirePublisher()

            if !publisher.isConnected, publisher.connectionState != .connecting {
                try await publisherShouldNegotiate()
            }

            try await publisherTransportConnectedCompleter.wait()
            try await publisherDataChannel.openCompleter.wait()
        }

        try await ensurePublisherConnected()

        // At this point publisher should be .connected and dc should be .open
        assert(publisher?.isConnected ?? false, "publisher is not .connected")
        let dataChannelIsOpen = await publisherDataChannel.isOpen
        assert(dataChannelIsOpen, "publisher data channel is not .open")

        // Should return true if successful
        try await publisherDataChannel.send(userPacket: userPacket, kind: kind)
    }
}

// MARK: - Internal

extension Engine {
    func configureTransports(connectResponse: SignalClient.ConnectResponse) async throws {
        func makeConfiguration() -> LKRTCConfiguration {
            let connectOptions = _state.connectOptions

            // Make a copy, instead of modifying the user-supplied RTCConfiguration object.
            let rtcConfiguration = LKRTCConfiguration.liveKitDefault()

            // Set iceServers provided by the server
            rtcConfiguration.iceServers = connectResponse.rtcIceServers

            if !connectOptions.iceServers.isEmpty {
                // Override with user provided iceServers
                rtcConfiguration.iceServers = connectOptions.iceServers.map { $0.toRTCType() }
            }

            if connectResponse.clientConfiguration.forceRelay == .enabled {
                rtcConfiguration.iceTransportPolicy = .relay
            }

            return rtcConfiguration
        }

        let rtcConfiguration = makeConfiguration()

        if case let .join(joinResponse) = connectResponse {
            log("Configuring transports with JOIN response...")

            guard subscriber == nil, publisher == nil else {
                log("Transports are already configured")
                return
            }

            // protocol v3
            subscriberPrimary = joinResponse.subscriberPrimary
            log("subscriberPrimary: \(joinResponse.subscriberPrimary)")

            let subscriber = try Transport(config: rtcConfiguration,
                                           target: .subscriber,
                                           primary: subscriberPrimary,
                                           delegate: self)

            let publisher = try Transport(config: rtcConfiguration,
                                          target: .publisher,
                                          primary: !subscriberPrimary,
                                          delegate: self)

            publisher.onOffer = { [weak self] offer in
                guard let self else { return }
                self.log("Publisher onOffer \(offer.sdp)")
                try await self.signalClient.send(offer: offer)
            }

            // data over pub channel for backwards compatibility

            let reliableDataChannel = publisher.dataChannel(for: LKRTCDataChannel.labels.reliable,
                                                            configuration: Engine.createDataChannelConfiguration())

            let lossyDataChannel = publisher.dataChannel(for: LKRTCDataChannel.labels.lossy,
                                                         configuration: Engine.createDataChannelConfiguration(maxRetransmits: 0))

            await publisherDataChannel.set(reliable: reliableDataChannel)
            await publisherDataChannel.set(lossy: lossyDataChannel)

            log("dataChannel.\(String(describing: reliableDataChannel?.label)) : \(String(describing: reliableDataChannel?.channelId))")
            log("dataChannel.\(String(describing: lossyDataChannel?.label)) : \(String(describing: lossyDataChannel?.channelId))")

            if !subscriberPrimary {
                // lazy negotiation for protocol v3+
                try await publisherShouldNegotiate()
            }

            self.subscriber = subscriber
            self.publisher = publisher

        } else if case .reconnect = connectResponse {
            log("[Connect] Configuring transports with RECONNECT response...")
            guard let subscriber, let publisher else {
                log("[Connect] Subscriber or Publisher is nil", .error)
                return
            }

            try subscriber.set(configuration: rtcConfiguration)
            try publisher.set(configuration: rtcConfiguration)
        }
    }
}

// MARK: - Execution control (Internal)

extension Engine {
    func executeIfConnected(_ block: @escaping @convention(block) () -> Void) {
        if case .connected = _state.connectionState {
            // execute immediately
            block()
        }
    }

    func execute(when condition: @escaping ConditionEvalFunc,
                 removeWhen removeCondition: @escaping ConditionEvalFunc,
                 _ block: @escaping () -> Void)
    {
        // already matches condition, execute immediately
        if _state.read({ condition($0, nil) }) {
            log("[execution control] executing immediately...")
            block()
        } else {
            _blockProcessQueue.async { [weak self] in
                guard let self else { return }

                // create an entry and enqueue block
                self.log("[execution control] enqueuing entry...")

                let entry = ConditionalExecutionEntry(executeCondition: condition,
                                                      removeCondition: removeCondition,
                                                      block: block)

                self._queuedBlocks.append(entry)
            }
        }
    }
}

// MARK: - Connection / Reconnection logic

public enum StartReconnectReason {
    case websocket
    case transport
    case networkSwitch
}

extension Engine {
    // full connect sequence, doesn't update connection state
    func fullConnectSequence(_ url: String, _ token: String) async throws {
        // This should never happen since Engine is owned by Room
        let room = try requireRoom()

        let connectResponse = try await signalClient.connect(url,
                                                             token,
                                                             connectOptions: _state.connectOptions,
                                                             reconnectMode: _state.reconnectMode,
                                                             adaptiveStream: room._state.options.adaptiveStream)
        // Check cancellation after WebSocket connected
        try Task.checkCancellation()

        _state.mutate { $0.connectStopwatch.split(label: "signal") }
        try await configureTransports(connectResponse: connectResponse)
        // Check cancellation after configuring transports
        try Task.checkCancellation()

        // Resume after configuring transports...
        await signalClient.resumeResponseQueue()

        // Wait for transport...
        try await primaryTransportConnectedCompleter.wait()

        _state.mutate { $0.connectStopwatch.split(label: "engine") }
        log("\(_state.connectStopwatch)")
    }

    func startReconnect(reason: StartReconnectReason) async throws {
        log("[Connect] Starting, reason: \(reason)")

        guard case .connected = _state.connectionState else {
            log("[Connect] Must be called with connected state", .error)
            throw LiveKitError(.invalidState)
        }

        guard let url = _state.url, let token = _state.token else {
            log("[Connect] Url or token is nil", .error)
            throw LiveKitError(.invalidState)
        }

        guard subscriber != nil, publisher != nil else {
            log("[Connect] Publisher or subscriber is nil", .error)
            throw LiveKitError(.invalidState)
        }

        _state.mutate {
            // Mark as Re-connecting
            $0.connectionState = .reconnecting
            $0.reconnectMode = .quick
        }

        // quick connect sequence, does not update connection state
        func quickReconnectSequence() async throws {
            log("[Connect] Starting .quick reconnect sequence...")

            // This should never happen since Engine is owned by Room
            let room = try requireRoom()

            let connectResponse = try await signalClient.connect(url,
                                                                 token,
                                                                 connectOptions: _state.connectOptions,
                                                                 reconnectMode: _state.reconnectMode,
                                                                 adaptiveStream: room._state.options.adaptiveStream)

            // Update configuration
            try await configureTransports(connectResponse: connectResponse)
            // Resume after configuring transports...
            await signalClient.resumeResponseQueue()

            log("[Connect] Waiting for socket to connect...")
            // Wait for primary transport to connect (if not already)
            try await primaryTransportConnectedCompleter.wait()

            // send SyncState before offer
            try await sendSyncState()

            subscriber?.isRestartingIce = true

            if let publisher, _state.hasPublished {
                // Only if published, wait for publisher to connect...
                log("[Connect] Waiting for publisher to connect...")
                try await publisher.createAndSendOffer(iceRestart: true)
                try await publisherTransportConnectedCompleter.wait()
            }
        }

        // "full" re-connection sequence
        // as a last resort, try to do a clean re-connection and re-publish existing tracks
        func fullReconnectSequence() async throws {
            log("[Connect] starting .full reconnect sequence...")

            try await cleanUp(isFullReconnect: true)

            guard let url = _state.url,
                  let token = _state.token
            else {
                log("[Connect] Url or token is nil")
                throw LiveKitError(.invalidState)
            }

            try await fullConnectSequence(url, token)
        }

        let retryingTask = Task.retrying(maxRetryCount: _state.connectOptions.reconnectAttempts,
                                         retryDelay: _state.connectOptions.reconnectAttemptDelay)
        { totalAttempts, currentAttempt in

            // Not reconnecting state anymore
            guard case .reconnecting = _state.connectionState else {
                self.log("[Connect] Not in reconnect state anymore, exiting retry cycle.")
                return
            }

            // Full reconnect failed, give up
            guard _state.reconnectMode != .full else { return }

            self.log("[Connect] Retry in \(_state.connectOptions.reconnectAttemptDelay) seconds, \(currentAttempt)/\(totalAttempts) tries left.")

            // Try full reconnect for the final attempt
            if totalAttempts == currentAttempt, _state.nextPreferredReconnectMode == nil {
                _state.mutate { $0.nextPreferredReconnectMode = .full }
            }

            let mode: ReconnectMode = self._state.mutate {
                let mode: ReconnectMode = ($0.nextPreferredReconnectMode == .full || $0.reconnectMode == .full) ? .full : .quick
                $0.reconnectMode = mode
                $0.nextPreferredReconnectMode = nil
                return mode
            }

            do {
                if case .quick = mode {
                    try await quickReconnectSequence()
                } else if case .full = mode {
                    try await fullReconnectSequence()
                }
            } catch {
                log("[Connect] Reconnect mode: \(mode) failed with error: \(error)", .error)
                // Re-throw
                throw error
            }
        }

        do {
            try await retryingTask.value
            // Re-connect sequence successful
            log("[Connect] Sequence completed")
            _state.mutate { $0.connectionState = .connected }
        } catch {
            log("[Connect] Sequence failed with error: \(error)")
            // Finally disconnect if all attempts fail
            try await cleanUp(withError: error)
        }
    }
}

// MARK: - Session Migration

extension Engine {
    func sendSyncState() async throws {
        let room = try requireRoom()

        guard let subscriber,
              let previousAnswer = subscriber.localDescription
        else {
            // No-op
            return
        }

        let previousOffer = subscriber.remoteDescription

        // 1. autosubscribe on, so subscribed tracks = all tracks - unsub tracks,
        //    in this case, we send unsub tracks, so server add all tracks to this
        //    subscribe pc and unsub special tracks from it.
        // 2. autosubscribe off, we send subscribed tracks.

        let autoSubscribe = _state.connectOptions.autoSubscribe
        let trackSids = room._state.remoteParticipants.values.flatMap { participant in
            participant._state.trackPublications.values
                .filter { $0.isSubscribed != autoSubscribe }
                .map(\.sid)
        }

        log("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids
            $0.participantTracks = []
            $0.subscribe = !autoSubscribe
        }

        try await signalClient.sendSyncState(answer: previousAnswer.toPBType(),
                                             offer: previousOffer?.toPBType(),
                                             subscription: subscription, publishTracks: room.localParticipant.publishedTracksInfo(),
                                             dataChannels: publisherDataChannel.infos())
    }
}

// MARK: - Private helpers

extension Engine {
    func requireRoom() throws -> Room {
        guard let room = _room else { throw LiveKitError(.invalidState, message: "Room is nil") }
        return room
    }

    func requirePublisher() throws -> Transport {
        guard let publisher else { throw LiveKitError(.invalidState, message: "Publisher is nil") }
        return publisher
    }
}

// MARK: - ConnectivityListenerDelegate

extension Engine: ConnectivityListenerDelegate {
    func connectivityListener(_: ConnectivityListener, didSwitch path: NWPath) {
        log("didSwitch path: \(path)")
        Task {
            // Network has been switched, e.g. wifi <-> cellular
            if case .connected = _state.connectionState {
                try await startReconnect(reason: .networkSwitch)
            }
        }
    }
}
