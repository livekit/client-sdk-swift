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

@_implementationOnly import WebRTC

#if canImport(Network)
    import Network
#endif

@objc
public class Room: NSObject, ObservableObject, Loggable {
    // MARK: - MulticastDelegate

    let _delegates = MulticastDelegate<RoomDelegate>()

    // MARK: - Public

    @objc
    /// Server assigned id of the Room.
    public var sid: Sid? { _state.sid }

    /// Server assigned id of the Room. *async* version of ``Room/sid``.
    @objc
    public func sid() async throws -> Sid {
        try await _sidCompleter.wait()
    }

    @objc
    public var name: String? { _state.name }

    /// Room's metadata.
    @objc
    public var metadata: String? { _state.metadata }

    @objc
    public var serverVersion: String? { _state.serverInfo?.version.nilIfEmpty }

    /// Region code the client is currently connected to.
    @objc
    public var serverRegion: String? { _state.serverInfo?.region.nilIfEmpty }

    /// Region code the client is currently connected to.
    @objc
    public var serverNodeId: String? { _state.serverInfo?.nodeID.nilIfEmpty }

    @objc
    public var remoteParticipants: [Identity: RemoteParticipant] { _state.remoteParticipants }

    @objc
    public var activeSpeakers: [Participant] { _state.activeSpeakers }

    /// If the current room has a participant with `recorder:true` in its JWT grant.
    @objc
    public var isRecording: Bool { _state.isRecording }

    @objc
    public var maxParticipants: Int { _state.maxParticipants }

    @objc
    public var participantCount: Int { _state.numParticipants }

    @objc
    public var publishersCount: Int { _state.numPublishers }

    // expose engine's vars
    @objc
    public var url: String? { _state.url }

    @objc
    public var token: String? { _state.token }

    /// Current ``ConnectionState`` of the ``Room``.
    @objc
    public var connectionState: ConnectionState { _state.connectionState }

    @objc
    public var disconnectError: LiveKitError? { _state.disconnectError }

    public var connectStopwatch: Stopwatch { _state.connectStopwatch }

    // MARK: - Internal

    public var e2eeManager: E2EEManager?

    @objc
    public lazy var localParticipant: LocalParticipant = .init(room: self)

    struct State: Equatable {
        var connectOptions: ConnectOptions
        var roomOptions: RoomOptions

        var connectionState: ConnectionState = .disconnected
        var disconnectError: LiveKitError?

        var sid: String?
        var name: String?
        var metadata: String?

        var remoteParticipants = [Identity: RemoteParticipant]()
        var activeSpeakers = [Participant]()

        var isRecording: Bool = false

        var maxParticipants: Int = 0
        var numParticipants: Int = 0
        var numPublishers: Int = 0

        var serverInfo: Livekit_ServerInfo?

        var url: String?
        var token: String?

        var subscriberPrimary: Bool = false

        // preferred reconnect mode which will be used only for next attempt
        var nextPreferredReconnectMode: ReconnectMode?
        var reconnectMode: ReconnectMode?

        var connectStopwatch = Stopwatch(label: "connect")
        var hasPublished: Bool = false

        @discardableResult
        mutating func updateRemoteParticipant(info: Livekit_ParticipantInfo, room: Room) -> RemoteParticipant {
            // Check if RemoteParticipant with same identity exists...
            if let participant = remoteParticipants[info.identity] { return participant }
            // Create new RemoteParticipant...
            let participant = RemoteParticipant(info: info,
                                                room: room,
                                                shouldNotify: connectionState == .connected)
            remoteParticipants[info.identity] = participant
            return participant
        }

        // Find RemoteParticipant by Sid
        func remoteParticipant(sid: Sid) -> RemoteParticipant? {
            remoteParticipants.values.first(where: { $0.sid == sid })
        }
    }

    var _state: StateSync<State>

    private let _sidCompleter = AsyncCompleter<Sid>(label: "sid", defaultTimeOut: .sid)

    typealias ConditionEvalFunc = (_ newState: State, _ oldState: State?) -> Bool

    let signalClient = SignalClient()
    var publisher: Transport?
    var subscriber: Transport?

    let primaryTransportConnectedCompleter = AsyncCompleter<Void>(label: "Primary transport connect", defaultTimeOut: .defaultTransportState)
    let publisherTransportConnectedCompleter = AsyncCompleter<Void>(label: "Publisher transport connect", defaultTimeOut: .defaultTransportState)

    private struct ConditionalExecutionEntry {
        let executeCondition: ConditionEvalFunc
        let removeCondition: ConditionEvalFunc
        let block: () -> Void
    }

    // MARK: - DataChannels

    lazy var subscriberDataChannel: DataChannelPairActor = .init(onDataPacket: { [weak self] dataPacket in
        guard let self else { return }
        switch dataPacket.value {
        case let .speaker(update): Task.detached { await self.onDidUpdateSpeakers(speakers: update.speakers) }
        case let .user(userPacket): Task.detached { await self.onDidReceiveUserPacket(packet: userPacket) }
        default: return
        }
    })

    private let publisherDataChannel = DataChannelPairActor()

    private var _blockProcessQueue = DispatchQueue(label: "LiveKitSDK.engine.pendingBlocks",
                                                   qos: .default)

    private var _queuedBlocks = [ConditionalExecutionEntry]()

    // MARK: Objective-C Support

    @objc
    override public convenience init() {
        self.init(delegate: nil,
                  connectOptions: ConnectOptions(),
                  roomOptions: RoomOptions())
    }

    @objc
    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil)
    {
        _state = StateSync(State(
            connectOptions: connectOptions ?? ConnectOptions(),
            roomOptions: roomOptions ?? RoomOptions()
        ))

        super.init()

        log()

        signalClient._delegate.set(delegate: self)

        ConnectivityListener.shared.add(delegate: self)

        if let delegate {
            log("delegate: \(String(describing: delegate))")
            _delegates.add(delegate: delegate)
        }

        // listen to app states
        AppStateListener.shared.add(delegate: self)

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self else { return }

            assert(!(newState.connectionState == .reconnecting && newState.reconnectMode == .none), "reconnectMode should not be .none")

            // sid updated
            if let sid = newState.sid, sid != oldState.sid {
                // Resolve sid
                self._sidCompleter.resume(returning: sid)
            }

            // metadata updated
            if let metadata = newState.metadata, metadata != oldState.metadata,
               // don't notify if empty string (first time only)
               oldState.metadata == nil ? !metadata.isEmpty : true
            {
                // Proceed only if connected...
                if case .connected = _state.connectionState {
                    _delegates.notify(label: { "room.didUpdate metadata: \(metadata)" }) {
                        $0.room?(self, didUpdateMetadata: metadata)
                    }
                }
            }

            // isRecording updated
            if newState.isRecording != oldState.isRecording {
                // Proceed only if connected...
                if case .connected = _state.connectionState {
                    _delegates.notify(label: { "room.didUpdate isRecording: \(newState.isRecording)" }) {
                        $0.room?(self, didUpdateIsRecording: newState.isRecording)
                    }
                }
            }

            if (newState.connectionState != oldState.connectionState) || (newState.reconnectMode != oldState.reconnectMode) {
                self.log("connectionState: \(oldState.connectionState) -> \(newState.connectionState), reconnectMode: \(String(describing: newState.reconnectMode))")
            }

            if newState.connectionState != oldState.connectionState {
                // connectionState did update

                // only if quick-reconnect
                if case .connected = newState.connectionState, case .quick = newState.reconnectMode {
                    resetTrackSettings()
                }

                // Re-send track permissions
                if case .connected = newState.connectionState {
                    Task.detached {
                        do {
                            try await self.localParticipant.sendTrackSubscriptionPermissions()
                        } catch {
                            self.log("Failed to send track subscription permissions, error: \(error)", .error)
                        }
                    }
                }

                _delegates.notify(label: { "room.didUpdate connectionState: \(newState.connectionState) oldValue: \(oldState.connectionState)" }) {
                    $0.room?(self, didUpdateConnectionState: newState.connectionState, from: oldState.connectionState)
                }

                // Individual connectionState delegates
                if case .connected = newState.connectionState {
                    // Connected
                    if case .reconnecting = oldState.connectionState {
                        _delegates.notify { $0.roomDidReconnect?(self) }
                    } else {
                        _delegates.notify { $0.roomDidConnect?(self) }
                    }
                } else if case .reconnecting = newState.connectionState {
                    // Re-connecting
                    _delegates.notify { $0.roomIsReconnecting?(self) }
                } else if case .disconnected = newState.connectionState {
                    // Disconnected
                    if case .connecting = oldState.connectionState {
                        _delegates.notify { $0.room?(self, didFailToConnectWithError: oldState.disconnectError) }
                    } else {
                        _delegates.notify { $0.room?(self, didDisconnectWithError: newState.disconnectError) }
                    }
                }
            }

            if newState.connectionState == .reconnecting, newState.reconnectMode == .full, oldState.reconnectMode != .full {
                // Started full reconnect
                Task.detached {
                    await self.cleanUpParticipants(notify: true)
                }
            }

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

            // Notify Room when state mutates
            Task.detached { @MainActor in
                self.objectWillChange.send()
            }
        }
    }

    deinit {
        log()
    }

    @objc
    public func connect(url: String,
                        token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) async throws
    {
        log("connecting to room...", .info)

        let state = _state.copy()

        // update options if specified
        if let roomOptions, roomOptions != state.roomOptions {
            _state.mutate { $0.roomOptions = roomOptions }
        }

        // enable E2EE
        if roomOptions?.e2eeOptions != nil {
            e2eeManager = E2EEManager(e2eeOptions: roomOptions!.e2eeOptions!)
            e2eeManager!.setup(room: self)
        }

        // try await engine.connect(url, token, connectOptions: connectOptions)

        // update options if specified
        if let connectOptions, connectOptions != _state.connectOptions {
            _state.mutate { $0.connectOptions = connectOptions }
        }

        await cleanUp()
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
            await cleanUp(withError: error)
            // Re-throw error
            throw error
        }

        log("Connected to \(String(describing: self))", .info)
    }

    @objc
    public func disconnect() async {
        // Return if already disconnected state
        if case .disconnected = connectionState { return }

        do {
            try await signalClient.sendLeave()
        } catch {
            log("Failed to send leave with error: \(error)")
        }

        await cleanUp()
    }
}

// MARK: - Internal

extension Room {
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
        await publisher.negotiate()
        _state.mutate { $0.hasPublished = true }
    }

    func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket.Kind) async throws {
        func ensurePublisherConnected() async throws {
            guard _state.subscriberPrimary else { return }

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

    // Resets state of Room
    func cleanUp(withError disconnectError: Error? = nil, isFullReconnect: Bool = false) async {
        log("withError: \(String(describing: disconnectError))")

        // Start Engine cleanUp sequence

        primaryTransportConnectedCompleter.reset()
        publisherTransportConnectedCompleter.reset()

        _state.mutate {
            // if isFullReconnect, keep connection related states
            $0 = isFullReconnect ? State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                connectionState: $0.connectionState,
                url: $0.url,
                token: $0.token,
                nextPreferredReconnectMode: $0.nextPreferredReconnectMode,
                reconnectMode: $0.reconnectMode
            ) : State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                connectionState: .disconnected,
                disconnectError: LiveKitError.from(error: disconnectError)
            )
        }

        await signalClient.cleanUp(withError: disconnectError)
        await cleanUpRTC()
        await cleanUpParticipants()

        // Cleanup for E2EE
        if let e2eeManager {
            e2eeManager.cleanUp()
        }

        // Reset state
        // _state.mutate { $0 = State(roomOptions: $0.roomOptions, connectOptions: $0.connectOptions) }

        // Reset completers
        _sidCompleter.reset()
    }
}

// MARK: - Internal

extension Room {
    func cleanUpParticipants(notify _notify: Bool = true) async {
        log("notify: \(_notify)")

        // Stop all local & remote tracks
        let allParticipants = ([[localParticipant], Array(_state.remoteParticipants.values)] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        // Clean up Participants concurrently
        await withTaskGroup(of: Void.self) { group in
            for participant in allParticipants {
                group.addTask {
                    await participant.cleanUp(notify: _notify)
                }
            }
        }

        _state.mutate {
            $0.remoteParticipants = [:]
        }
    }

    func _onParticipantDidDisconnect(identity: Identity) async throws {
        guard let participant = _state.mutate({ $0.remoteParticipants.removeValue(forKey: identity) }) else {
            throw LiveKitError(.invalidState, message: "Participant not found for \(identity)")
        }

        await participant.cleanUp(notify: true)
    }
}

// MARK: - Debugging

public extension Room {
    func debug_sendSimulate(scenario: SimulateScenario) async throws {
        try await engine.signalClient.sendSimulate(scenario: scenario)
    }

    func debug_triggerReconnect(reason: StartReconnectReason) async throws {
        try await engine.startReconnect(reason: reason)
    }
}

// MARK: - Session Migration

extension Room {
    func resetTrackSettings() {
        log("resetting track settings...")

        // create an array of RemoteTrackPublication
        let remoteTrackPublications = _state.remoteParticipants.values.map {
            $0._state.trackPublications.values.compactMap { $0 as? RemoteTrackPublication }
        }.joined()

        // reset track settings for all RemoteTrackPublication
        for publication in remoteTrackPublications {
            publication.resetTrackSettings()
        }
    }
}

// MARK: - Internal

extension Room {
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
            let subscriberPrimary = joinResponse.subscriberPrimary
            log("subscriberPrimary: \(joinResponse.subscriberPrimary)")

            _state.mutate {
                $0.subscriberPrimary = subscriberPrimary
            }

            let subscriber = try Transport(config: rtcConfiguration,
                                           target: .subscriber,
                                           primary: subscriberPrimary,
                                           delegate: self)

            let publisher = try Transport(config: rtcConfiguration,
                                          target: .publisher,
                                          primary: !subscriberPrimary,
                                          delegate: self)

            await publisher.set { [weak self] offer in
                guard let self else { return }
                self.log("Publisher onOffer \(offer.sdp)")
                try await self.signalClient.send(offer: offer)
            }

            // data over pub channel for backwards compatibility

            let reliableDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.labels.reliable,
                                                                  configuration: Self.createDataChannelConfiguration())

            let lossyDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.labels.lossy,
                                                               configuration: Self.createDataChannelConfiguration(maxRetransmits: 0))

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

            try await subscriber.set(configuration: rtcConfiguration)
            try await publisher.set(configuration: rtcConfiguration)
        }
    }
}

// MARK: - Execution control (Internal)

extension Room {
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

extension Room {
    // full connect sequence, doesn't update connection state
    func fullConnectSequence(_ url: String, _ token: String) async throws {
        let connectResponse = try await signalClient.connect(url,
                                                             token,
                                                             connectOptions: _state.connectOptions,
                                                             reconnectMode: _state.reconnectMode,
                                                             adaptiveStream: _state.roomOptions.adaptiveStream)
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

            let connectResponse = try await signalClient.connect(url,
                                                                 token,
                                                                 connectOptions: _state.connectOptions,
                                                                 reconnectMode: _state.reconnectMode,
                                                                 adaptiveStream: _state.roomOptions.adaptiveStream)

            // Update configuration
            try await configureTransports(connectResponse: connectResponse)
            // Resume after configuring transports...
            await signalClient.resumeResponseQueue()

            log("[Connect] Waiting for socket to connect...")
            // Wait for primary transport to connect (if not already)
            try await primaryTransportConnectedCompleter.wait()

            // send SyncState before offer
            try await sendSyncState()

            await subscriber?.setIsRestartingIce()

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

            await cleanUp(isFullReconnect: true)

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
            await cleanUp(withError: error)
        }
    }
}

// MARK: - Session Migration

extension Room {
    func sendSyncState() async throws {
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
        let trackSids = _state.remoteParticipants.values.flatMap { participant in
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
                                             subscription: subscription, publishTracks: localParticipant.publishedTracksInfo(),
                                             dataChannels: publisherDataChannel.infos())
    }
}

// MARK: - Private helpers

extension Room {
    func requirePublisher() throws -> Transport {
        guard let publisher else { throw LiveKitError(.invalidState, message: "Publisher is nil") }
        return publisher
    }
}
