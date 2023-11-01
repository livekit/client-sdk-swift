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
import Promises

#if canImport(Network)
import Network
#endif

@_implementationOnly import WebRTC

internal class Engine: MulticastDelegate<EngineDelegate> {

    internal let queue = DispatchQueue(label: "LiveKitSDK.engine", qos: .default)

    // MARK: - Public

    public typealias ConditionEvalFunc = (_ newState: State, _ oldState: State?) -> Bool

    internal struct State: ReconnectableState, Equatable {
        var connectOptions: ConnectOptions
        var url: String?
        var token: String?
        // preferred reconnect mode which will be used only for next attempt
        var nextPreferredReconnectMode: ReconnectMode?
        var reconnectMode: ReconnectMode?
        var connectionState: ConnectionState = .disconnected()
        var connectStopwatch = Stopwatch(label: "connect")
        var hasPublished: Bool = false
    }

    internal let primaryTransportConnectedCompleter = AsyncCompleter<Void>(label: "Primary transport connect", timeOut: .defaultTransportState)
    internal let publisherTransportConnectedCompleter = AsyncCompleter<Void>(label: "Publisher transport connect", timeOut: .defaultTransportState)

    public var _state: StateSync<State>

    public let signalClient = SignalClient()

    public internal(set) var publisher: Transport?
    public internal(set) var subscriber: Transport?

    // weak ref to Room
    public weak var _room: Room?

    private func requireRoom() async throws -> Room {
        guard let room = _room else { throw EngineError.state(message: "Room is nil") }
        return room
    }

    private func requirePublisher() async throws -> Transport {
        guard let publisher = publisher else { throw EngineError.state(message: "Publisher is nil") }
        return publisher
    }

    // MARK: - Private

    private struct ConditionalExecutionEntry {
        let executeCondition: ConditionEvalFunc
        let removeCondition: ConditionEvalFunc
        let block: () -> Void
    }

    internal var subscriberPrimary: Bool = false
    private var primary: Transport? { subscriberPrimary ? subscriber : publisher }

    // MARK: - DataChannels

    internal var subscriberDC = DataChannelPair(target: .subscriber)
    internal var publisherDC = DataChannelPair(target: .publisher)

    private var _blockProcessQueue = DispatchQueue(label: "LiveKitSDK.engine.pendingBlocks",
                                                   qos: .default)

    private var _queuedBlocks = [ConditionalExecutionEntry]()

    init(connectOptions: ConnectOptions) {

        self._state = StateSync(State(connectOptions: connectOptions))
        super.init()

        // log sdk & os versions
        log("sdk: \(LiveKit.version), os: \(String(describing: Utils.os()))(\(Utils.osVersionString())), modelId: \(String(describing: Utils.modelIdentifier() ?? "unknown"))")

        signalClient.add(delegate: self)
        ConnectivityListener.shared.add(delegate: self)

        // trigger events when state mutates
        self._state.onDidMutate = { [weak self] newState, oldState in

            guard let self = self else { return }

            assert(!(newState.connectionState == .reconnecting && newState.reconnectMode == .none), "reconnectMode should not be .none")

            if (newState.connectionState != oldState.connectionState) || (newState.reconnectMode != oldState.reconnectMode) {
                self.log("connectionState: \(oldState.connectionState) -> \(newState.connectionState), reconnectMode: \(String(describing: newState.reconnectMode))")
            }

            self.notify { $0.engine(self, didMutate: newState, oldState: oldState) }

            // execution control
            self._blockProcessQueue.async { [weak self] in
                guard let self = self, !self._queuedBlocks.isEmpty else { return }

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

        subscriberDC.onDataPacket = { [weak self] (dataPacket: Livekit_DataPacket) in

            guard let self = self else { return }

            switch dataPacket.value {
            case .speaker(let update): self.notify { $0.engine(self, didUpdate: update.speakers) }
            case .user(let userPacket): self.notify { $0.engine(self, didReceive: userPacket) }
            default: return
            }
        }
    }

    deinit {
        log()
    }

    // Connect sequence, resets existing state
    func connect(_ url: String,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil) async throws {

        // update options if specified
        if let connectOptions = connectOptions, connectOptions != _state.connectOptions {
            _state.mutate { $0.connectOptions = connectOptions }
        }

        try await cleanUp()

        _state.mutate { $0.connectionState = .connecting }

        do {
            try await fullConnectSequence(url, token)

            // Connect sequence successful
            log("Connect sequence completed")

            // update internal vars (only if connect succeeded)
            _state.mutate {
                $0.url = url
                $0.token = token
                $0.connectionState = .connected
            }

        } catch let error {
            try await cleanUp(reason: .networkError(error))
        }
    }

    // cleanUp (reset) both Room & Engine's state
    func cleanUp(reason: DisconnectReason? = nil, isFullReconnect: Bool = false) async throws {
        // This should never happen since Engine is owned by Room
        let room = try await requireRoom()
        // Call Room's cleanUp
        try room.cleanUp(reason: reason, isFullReconnect: isFullReconnect)
    }

    // Resets state of transports
    func cleanUpRTC() async throws {
        // Close data channels
        self.publisherDC.close()
        self.subscriberDC.close()

        // Close transports
        await publisher?.close()
        self.publisher = nil

        await subscriber?.close()
        self.subscriber = nil

        // Reset publish state
        self._state.mutate { $0.hasPublished = false }
    }

    func publisherShouldNegotiate() async throws {

        log()

        let publisher = try await requirePublisher()
        publisher.negotiate()
        self._state.mutate { $0.hasPublished = true }
    }

    func send(userPacket: Livekit_UserPacket, reliability: Reliability = .reliable) async throws {

        func ensurePublisherConnected () async throws {

            guard subscriberPrimary else { return }

            let publisher = try await requirePublisher()

            if !publisher.isConnected, publisher.connectionState != .connecting {
                try await publisherShouldNegotiate()
            }

            try await publisherTransportConnectedCompleter.wait()
            try await publisherDC.openCompleter.wait()
        }

        try await ensurePublisherConnected()

        // At this point publisher should be .connected and dc should be .open
        assert(self.publisher?.isConnected ?? false, "publisher is not .connected")
        assert(self.publisherDC.isOpen, "publisher data channel is not .open")

        // Should return true if successful
        try publisherDC.send(userPacket: userPacket, reliability: reliability)
    }
}

// MARK: - Internal

internal extension Engine {

    func configureTransports(joinResponse: Livekit_JoinResponse) async throws {

        log("Configuring transports...")

        guard subscriber == nil, publisher == nil else {
            log("Transports are already configured")
            return
        }

        // protocol v3
        subscriberPrimary = joinResponse.subscriberPrimary
        log("subscriberPrimary: \(joinResponse.subscriberPrimary)")

        let connectOptions = self._state.connectOptions

        // Make a copy, instead of modifying the user-supplied RTCConfiguration object.
        let rtcConfiguration = LKRTCConfiguration.liveKitDefault()

        // Set iceServers provided by the server
        rtcConfiguration.iceServers = joinResponse.iceServers.map { $0.toRTCType() }

        if !connectOptions.iceServers.isEmpty {
            // Override with user provided iceServers
            rtcConfiguration.iceServers = connectOptions.iceServers.map { $0.toRTCType() }
        }

        if joinResponse.clientConfiguration.forceRelay == .enabled {
            rtcConfiguration.iceTransportPolicy = .relay
        }

        let subscriber = try Transport(config: rtcConfiguration,
                                       target: .subscriber,
                                       primary: subscriberPrimary,
                                       delegate: self)

        let publisher = try Transport(config: rtcConfiguration,
                                      target: .publisher,
                                      primary: !subscriberPrimary,
                                      delegate: self)

        publisher.onOffer = { [weak self] offer in
            guard let self = self else { return }
            log("Publisher onOffer \(offer.sdp)")
            try await signalClient.send(offer: offer)
        }

        // data over pub channel for backwards compatibility

        let publisherReliableDC = publisher.dataChannel(for: LKRTCDataChannel.labels.reliable,
                                                        configuration: Engine.createDataChannelConfiguration())

        let publisherLossyDC = publisher.dataChannel(for: LKRTCDataChannel.labels.lossy,
                                                     configuration: Engine.createDataChannelConfiguration(maxRetransmits: 0))

        publisherDC.set(reliable: publisherReliableDC)
        publisherDC.set(lossy: publisherLossyDC)

        log("dataChannel.\(String(describing: publisherReliableDC?.label)) : \(String(describing: publisherReliableDC?.channelId))")
        log("dataChannel.\(String(describing: publisherLossyDC?.label)) : \(String(describing: publisherLossyDC?.channelId))")

        if !subscriberPrimary {
            // lazy negotiation for protocol v3+
            try await publisherShouldNegotiate()
        }

        self.subscriber = subscriber
        self.publisher = publisher
    }
}

// MARK: - Execution control (Internal)

internal extension Engine {

    func executeIfConnected(_ block: @escaping @convention(block) () -> Void) {

        if case .connected = _state.connectionState {
            // execute immediately
            block()
        }
    }

    func execute(when condition: @escaping ConditionEvalFunc,
                 removeWhen removeCondition: @escaping ConditionEvalFunc,
                 _ block: @escaping () -> Void) {

        // already matches condition, execute immediately
        if _state.read({ condition($0, nil) }) {
            log("[execution control] executing immediately...")
            block()
        } else {
            _blockProcessQueue.async { [weak self] in
                guard let self = self else { return }

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

internal extension Engine {

    // full connect sequence, doesn't update connection state
    func fullConnectSequence(_ url: String, _ token: String) async throws {
        // This should never happen since Engine is owned by Room
        let room = try await requireRoom()

        try await signalClient.connect(url,
                                       token,
                                       connectOptions: _state.connectOptions,
                                       reconnectMode: _state.reconnectMode,
                                       adaptiveStream: room._state.options.adaptiveStream)

        let jr = try await signalClient.joinResponseCompleter.wait()
        _state.mutate { $0.connectStopwatch.split(label: "signal") }
        try await configureTransports(joinResponse: jr)
        try await signalClient.resumeResponseQueue()
        try await primaryTransportConnectedCompleter.wait()
        _state.mutate { $0.connectStopwatch.split(label: "engine") }
        log("\(self._state.connectStopwatch)")
    }

    func startReconnect() async throws {

        guard case .connected = _state.connectionState else {
            log("[reconnect] must be called with connected state", .warning)
            throw EngineError.state(message: "Must be called with connected state")
        }

        guard let url = _state.url, let token = _state.token else {
            log("[reconnect] url or token is nil", . warning)
            throw EngineError.state(message: "url or token is nil")
        }

        guard subscriber != nil, publisher != nil else {
            log("[reconnect] publisher or subscriber is nil", .warning)
            throw EngineError.state(message: "Publisher or Subscriber is nil")
        }

        // quick connect sequence, does not update connection state
        func quickReconnectSequence() async throws {
            log("[Reconnect] Starting .quick reconnect sequence...")

            // This should never happen since Engine is owned by Room
            let room = try await requireRoom()

            try await signalClient.connect(url,
                                           token,
                                           connectOptions: _state.connectOptions,
                                           reconnectMode: _state.reconnectMode,
                                           adaptiveStream: room._state.options.adaptiveStream)

            log("[Reconnect] waiting for socket to connect...")
            // Wait for primary transport to connect (if not already)
            try await primaryTransportConnectedCompleter.wait()

            // send SyncState before offer
            try await sendSyncState()

            subscriber?.isRestartingIce = true

            // Only if published, continue...
            guard let publisher = publisher, _state.hasPublished else { return }

            log("[reconnect] waiting for publisher to connect...")

            try await publisher.createAndSendOffer(iceRestart: true)
            try await publisherTransportConnectedCompleter.wait()

            log("[reconnect] Sending queued requests...")
            // always check if there are queued requests
            try await signalClient.sendQueuedRequests()
        }

        // "full" re-connection sequence
        // as a last resort, try to do a clean re-connection and re-publish existing tracks
        func fullReconnectSequence() async throws {
            log("[Reconnect] starting .full reconnect sequence...")
            try await cleanUp(isFullReconnect: true)

            guard let url = self._state.url,
                  let token = self._state.token else {
                throw EngineError.state(message: "url or token is nil")
            }

            try await fullConnectSequence(url, token)
        }

        return retry(on: queue,
                     attempts: _state.connectOptions.reconnectAttempts,
                     delay: _state.connectOptions.reconnectAttemptDelay,
                     condition: { [weak self] triesLeft, _ in
                        guard let self = self else { return false }

                        // not reconnecting state anymore
                        guard case .reconnecting = self._state.connectionState else { return false }

                        // full reconnect failed, give up
                        guard .full != self._state.reconnectMode else { return false }

                        self.log("[reconnect] retry in \(self._state.connectOptions.reconnectAttemptDelay) seconds, \(triesLeft) tries left...")

                        // try full reconnect for the final attempt
                        if triesLeft == 1,
                           self._state.nextPreferredReconnectMode == nil {
                            self._state.mutate {  $0.nextPreferredReconnectMode = .full }
                        }

                        return true
                     }, _: { [weak self] in
                        // this should never happen
                        guard let self = self else { return Promise(EngineError.state(message: "self is nil")) }

                        let mode: ReconnectMode = self._state.mutate {

                            let mode: ReconnectMode = ($0.nextPreferredReconnectMode == .full || $0.reconnectMode == .full) ? .full : .quick
                            $0.connectionState = .reconnecting
                            $0.reconnectMode = mode
                            $0.nextPreferredReconnectMode = nil

                            return mode
                        }

                        return mode == .full ? fullReconnectSequence() : quickReconnectSequence()
                     })
            .then(on: queue) {
                // re-connect sequence successful
                self.log("[reconnect] sequence completed")
                self._state.mutate { $0.connectionState = .connected }
            }.catch(on: queue) { error in
                self.log("[reconnect] sequence failed with error: \(error)")
                // finally disconnect if all attempts fail
                self.cleanUp(reason: .networkError(error))
            }
    }

}

// MARK: - Session Migration

internal extension Engine {

    func sendSyncState() async throws {

        let room = try await requireRoom()

        guard let subscriber = subscriber,
              let previousAnswer = subscriber.localDescription else {
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
            participant._state.tracks.values
                .filter { $0.subscribed != autoSubscribe }
                .map { $0.sid }
        }

        log("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids
            $0.participantTracks = []
            $0.subscribe = !autoSubscribe
        }

        try await signalClient.sendSyncState(answer: previousAnswer.toPBType(),
                                             offer: previousOffer?.toPBType(),
                                             subscription: subscription, publishTracks: room._state.localParticipant?.publishedTracksInfo(),
                                             dataChannels: publisherDC.infos())
    }
}

// MARK: - ConnectivityListenerDelegate

extension Engine: ConnectivityListenerDelegate {

    func connectivityListener(_: ConnectivityListener, didSwitch path: NWPath) {
        log("didSwitch path: \(path)")
        Task {
            // Network has been switched, e.g. wifi <-> cellular
            if case .connected = _state.connectionState {
                log("[Reconnect] Starting, reason: network path changed")
                try await startReconnect()
            }
        }
    }
}
