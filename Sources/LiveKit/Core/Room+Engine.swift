/*
 * Copyright 2026 LiveKit
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

// swiftlint:disable file_length

import Foundation

#if canImport(Network)
import Network
#endif

internal import LiveKitWebRTC

// Room+Engine
extension Room {
    // MARK: - Public

    typealias ConditionEvalFunc = @Sendable (_ newState: State, _ oldState: State?) -> Bool

    // MARK: - Private

    struct ConditionalExecutionEntry {
        let executeCondition: ConditionEvalFunc
        let removeCondition: ConditionEvalFunc
        let block: @Sendable () -> Void
    }

    // Resets state of transports
    func cleanUpRTC() async {
        // Close data channels
        publisherDataChannel.reset()
        subscriberDataChannel.reset()

        await _state.transport?.close()

        // Reset publish state
        _state.mutate {
            $0.transport = nil
            $0.hasPublished = false
        }
    }

    func publisherShouldNegotiate() async throws {
        log()

        let publisher = try requirePublisher()
        await publisher.negotiate()
        _state.mutate { $0.hasPublished = true }
    }

    func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket.Kind) async throws {
        try await send(dataPacket: .with {
            $0.user = userPacket
            $0.kind = kind
        })
    }

    func send(dataPacket packet: Livekit_DataPacket) async throws {
        func ensurePublisherConnected() async throws {
            // Only needed when subscriber is primary in dual PC mode
            guard case .subscriberPrimary = _state.transport else {
                return
            }

            let publisher = try requirePublisher()

            let connectionState = await publisher.connectionState
            if connectionState != .connected, connectionState != .connecting {
                try await publisherShouldNegotiate()
            }

            try await publisherTransportConnectedCompleter.wait(timeout: _state.connectOptions.publisherTransportConnectTimeout)
            try await publisherDataChannel.openCompleter.wait()
        }

        try await ensurePublisherConnected()

        // At this point publisher should be .connected and dc should be .open
        if await !(_state.transport?.publisher.isConnected ?? false) {
            log("publisher is not .connected", .error)
        }

        let dataChannelIsOpen = publisherDataChannel.isOpen
        if !dataChannelIsOpen {
            log("publisher data channel is not .open", .error)
        }

        var packet = packet
        if let identity = localParticipant.identity?.stringValue {
            packet.participantIdentity = identity
        }
        if let sid = localParticipant.sid?.stringValue {
            packet.participantSid = sid
        }

        try await publisherDataChannel.send(dataPacket: packet)
    }
}

// MARK: - Internal

extension Room {
    // swiftlint:disable:next function_body_length
    func configureTransports(connectResponse: SignalClient.ConnectResponse, singlePeerConnection: Bool) async throws {
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
            } else {
                rtcConfiguration.iceTransportPolicy = connectOptions.iceTransportPolicy.toRTCType()
            }

            rtcConfiguration.enableDscp = connectOptions.isDscpEnabled

            return rtcConfiguration
        }

        let rtcConfiguration = makeConfiguration()

        if case let .join(joinResponse) = connectResponse {
            log("Configuring transports with JOIN response...")

            guard _state.transport == nil else {
                log("Transports are already configured")
                return
            }

            let isSinglePC = singlePeerConnection
            let isSubscriberPrimary = isSinglePC ? false : joinResponse.subscriberPrimary
            log("subscriberPrimary: \(isSubscriberPrimary), singlePeerConnection: \(isSinglePC)")

            // Publisher always created; is primary in single PC mode
            let publisher = try Transport(config: rtcConfiguration,
                                          target: .publisher,
                                          primary: isSinglePC || !isSubscriberPrimary,
                                          delegate: self)

            await publisher.set { [weak self] offer, offerId in
                guard let self else { return }
                log("Publisher onOffer with offerId: \(offerId), sdp: \(offer.sdp)")
                try await signalClient.send(offer: offer, offerId: offerId)
            }

            // data over pub channel for backwards compatibility

            let reliableDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.Labels.reliable,
                                                                  configuration: RTC.createDataChannelConfiguration())

            let lossyDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.Labels.lossy,
                                                               configuration: RTC.createDataChannelConfiguration(ordered: false, maxRetransmits: 0))

            publisherDataChannel.set(reliable: reliableDataChannel)
            publisherDataChannel.set(lossy: lossyDataChannel)

            log("dataChannel.\(String(describing: reliableDataChannel?.label)) : \(String(describing: reliableDataChannel?.channelId))")
            log("dataChannel.\(String(describing: lossyDataChannel?.label)) : \(String(describing: lossyDataChannel?.channelId))")

            let subscriber = isSinglePC ? nil : try Transport(config: rtcConfiguration,
                                                              target: .subscriber,
                                                              primary: isSubscriberPrimary,
                                                              delegate: self)

            let transport: TransportMode = if let subscriber, isSubscriberPrimary {
                .subscriberPrimary(publisher: publisher, subscriber: subscriber)
            } else if let subscriber {
                .publisherPrimary(publisher: publisher, subscriber: subscriber)
            } else {
                .publisherOnly(publisher: publisher)
            }
            _state.mutate { $0.transport = transport }

            log("[Connect] Fast publish enabled: \(joinResponse.fastPublish ? "true" : "false")")
            if isSinglePC || !isSubscriberPrimary || joinResponse.fastPublish {
                // In single PC mode or when publisher is primary, negotiate immediately
                try await publisherShouldNegotiate()
            }

        } else if case let .reconnect(reconnectResponse) = connectResponse {
            log("[Connect] Configuring transports with RECONNECT response...")
            try await _state.transport?.set(configuration: rtcConfiguration)
            publisherDataChannel.retryReliable(lastSequence: reconnectResponse.lastMessageSeq)
        }
    }
}

// MARK: - Execution control (Internal)

extension Room {
    func execute(when condition: @escaping ConditionEvalFunc,
                 removeWhen removeCondition: @escaping ConditionEvalFunc,
                 _ block: @Sendable @escaping () -> Void)
    {
        // already matches condition, execute immediately
        if _state.read({ condition($0, nil) }) {
            log("[execution control] executing immediately...")
            block()
        } else {
            _blockProcessQueue.async { [weak self] in
                guard let self else { return }

                // create an entry and enqueue block
                log("[execution control] enqueuing entry...")

                let entry = ConditionalExecutionEntry(executeCondition: condition,
                                                      removeCondition: removeCondition,
                                                      block: block)

                _queuedBlocks.append(entry)
            }
        }
    }
}

// MARK: - Connection / Reconnection logic

public enum StartReconnectReason: Sendable {
    case websocket
    case transport
    case networkSwitch
    case debug
}

// Room+ConnectSequences
extension Room {
    // full connect sequence, doesn't update connection state
    func fullConnectSequence(_ url: URL, _ token: String) async throws {
        var singlePC = _state.roomOptions.singlePeerConnection

        let connectResponse: SignalClient.ConnectResponse
        do {
            connectResponse = try await signalClient.connect(url,
                                                             token,
                                                             connectOptions: _state.connectOptions,
                                                             reconnectMode: _state.isReconnectingWithMode,
                                                             adaptiveStream: _state.roomOptions.adaptiveStream,
                                                             singlePeerConnection: singlePC)
        } catch let error as LiveKitError where error.type == .serviceNotFound && singlePC {
            log("v1 RTC path not supported, retrying with legacy path", .warning)
            singlePC = false
            connectResponse = try await signalClient.connect(url,
                                                             token,
                                                             connectOptions: _state.connectOptions,
                                                             reconnectMode: _state.isReconnectingWithMode,
                                                             adaptiveStream: _state.roomOptions.adaptiveStream,
                                                             singlePeerConnection: false)
        }

        // Check cancellation after WebSocket connected
        try Task.checkCancellation()

        _state.mutate { $0.connectStopwatch.split(label: "signal") }
        try await configureTransports(connectResponse: connectResponse, singlePeerConnection: singlePC)
        // Check cancellation after configuring transports
        try Task.checkCancellation()

        // Resume after configuring transports...
        await signalClient.resumeQueues()

        // Wait for transport...
        try await primaryTransportConnectedCompleter.wait(timeout: _state.connectOptions.primaryTransportConnectTimeout)
        try Task.checkCancellation()

        _state.mutate { $0.connectStopwatch.split(label: "engine") }
        log("\(_state.connectStopwatch)")
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func startReconnect(reason: StartReconnectReason, nextReconnectMode: ReconnectMode? = nil) async throws {
        log("[Connect] Starting, reason: \(reason)")

        guard case .connected = _state.connectionState else {
            log("[Connect] Must be called with connected state", .error)
            throw LiveKitError(.invalidState)
        }

        let url = _state.read { $0.connectedUrl ?? $0.providedUrl }
        guard let url, let token = _state.token else {
            log("[Connect] Url or token is nil", .error)
            throw LiveKitError(.invalidState)
        }

        guard _state.transport != nil else {
            log("[Connect] Transport is nil", .error)
            throw LiveKitError(.invalidState)
        }

        guard _state.isReconnectingWithMode == nil else {
            log("[Connect] Reconnect already in progress...", .warning)
            throw LiveKitError(.invalidState)
        }

        _state.mutate {
            // Mark as Re-connecting internally
            $0.isReconnectingWithMode = .quick
            $0.nextReconnectMode = nextReconnectMode
        }

        // quick connect sequence, does not update connection state
        @Sendable func quickReconnectSequence() async throws {
            log("[Connect] Starting .quick reconnect sequence...")

            let singlePC = await !signalClient.useV0SignalPath
            let connectResponse = try await signalClient.connect(url,
                                                                 token,
                                                                 connectOptions: _state.connectOptions,
                                                                 reconnectMode: _state.isReconnectingWithMode,
                                                                 participantSid: localParticipant.sid,
                                                                 adaptiveStream: _state.roomOptions.adaptiveStream,
                                                                 singlePeerConnection: singlePC)
            try Task.checkCancellation()

            // Update configuration
            try await configureTransports(connectResponse: connectResponse,
                                          singlePeerConnection: singlePC)
            try Task.checkCancellation()

            // Resume after configuring transports...
            await signalClient.resumeQueues()

            log("[Connect] Waiting for subscriber to connect...")
            // Wait for primary transport to connect (if not already)
            do {
                try await primaryTransportConnectedCompleter.wait(timeout: _state.connectOptions.primaryTransportConnectTimeout)
                log("[Connect] Subscriber transport connected")
            } catch {
                log("[Connect] Subscriber transport failed to connect, error: \(error)", .error)
                throw error
            }
            try Task.checkCancellation()

            // send SyncState before offer
            try await sendSyncState()

            await _state.transport?.setSubscriberRestartingIce()

            if let publisher = _state.transport?.publisher, _state.hasPublished {
                // Only if published, wait for publisher to connect...
                log("[Connect] Waiting for publisher to connect...")
                try await publisher.createAndSendOffer(iceRestart: true)
                do {
                    try await publisherTransportConnectedCompleter.wait(timeout: _state.connectOptions.publisherTransportConnectTimeout)
                    log("[Connect] Publisher transport connected")
                } catch {
                    log("[Connect] Publisher transport failed to connect, error: \(error)", .error)
                    throw error
                }
            }
        }

        // "full" re-connection sequence
        // as a last resort, try to do a clean re-connection and re-publish existing tracks
        @Sendable func fullReconnectSequence() async throws {
            log("[Connect] starting .full reconnect sequence...")

            _state.mutate {
                // Mark as Re-connecting
                $0.connectionState = .reconnecting
            }

            let (providedUrl, connectedUrl, token) = _state.read { ($0.providedUrl, $0.connectedUrl, $0.token) }

            guard let providedUrl, let connectedUrl, let token else {
                log("[Connect] Url or token is nil")
                throw LiveKitError(.invalidState)
            }

            let finalUrl: URL
            await cleanUp(isFullReconnect: true)
            if providedUrl.isCloud {
                guard let regionManager = await regionManager(for: providedUrl) else {
                    throw LiveKitError(.onlyForCloud)
                }

                finalUrl = try await connectWithCloudRegionFailover(regionManager: regionManager,
                                                                    initialUrl: connectedUrl,
                                                                    initialRegion: nil,
                                                                    token: token)
            } else {
                try await fullConnectSequence(connectedUrl, token)
                finalUrl = connectedUrl
            }

            _state.mutate { $0.connectedUrl = finalUrl }
        }

        do {
            let reconnectTask = Task.retrying(totalAttempts: _state.connectOptions.reconnectAttempts,
                                              retryDelay: { @Sendable attempt in
                                                  let delay = TimeInterval.computeReconnectDelay(forAttempt: attempt,
                                                                                                 baseDelay: self._state.connectOptions.reconnectAttemptDelay,
                                                                                                 maxDelay: self._state.connectOptions.reconnectMaxDelay,
                                                                                                 totalAttempts: self._state.connectOptions.reconnectAttempts,
                                                                                                 addJitter: true)
                                                  self.log("[Connect] Retry cycle waiting for \(String(format: "%.2f", delay)) seconds before attempt \(attempt + 1)")
                                                  return delay
                                              }) { currentAttempt, totalAttempts in
                // Not reconnecting state anymore
                guard let currentMode = self._state.isReconnectingWithMode else {
                    self.log("[Connect] Not in reconnect state anymore, exiting retry cycle.")
                    return
                }

                // Full reconnect failed, give up
                guard currentMode != .full else { return }

                self.log("[Connect] Starting retry attempt \(currentAttempt)/\(totalAttempts) with mode: \(currentMode)")

                // Try full reconnect for the final attempt
                if totalAttempts == currentAttempt, self._state.nextReconnectMode == nil {
                    self._state.mutate { $0.nextReconnectMode = .full }
                }

                let mode: ReconnectMode = self._state.mutate {
                    let mode: ReconnectMode = ($0.nextReconnectMode == .full || $0.isReconnectingWithMode == .full) ? .full : .quick
                    $0.isReconnectingWithMode = mode
                    $0.nextReconnectMode = nil
                    return mode
                }

                do {
                    if case .quick = mode {
                        try await quickReconnectSequence()
                        self.log("[Connect] Quick reconnect succeeded for attempt \(currentAttempt)")
                    } else if case .full = mode {
                        try await fullReconnectSequence()
                        self.log("[Connect] Full reconnect succeeded for attempt \(currentAttempt)")
                    }
                } catch {
                    self.log("[Connect] Reconnect mode: \(mode) failed with error: \(error)", .error)
                    // Re-throw
                    throw error
                }
            }

            _state.mutate {
                $0.reconnectTask = reconnectTask.cancellable()
            }

            try await reconnectTask.value

            // Re-connect sequence successful
            log("[Connect] Sequence completed")
            _state.mutate {
                $0.connectionState = .connected
                $0.reconnectTask = nil
                $0.isReconnectingWithMode = nil
                $0.nextReconnectMode = nil
            }

            if let providedUrl = _state.providedUrl, providedUrl.isCloud, let regionManager = await regionManager(for: providedUrl) {
                // Clear failed region attempts after a successful reconnect.
                await regionManager.resetAttempts()
            }
        } catch {
            log("[Connect] Sequence failed with error: \(error)")

            if !Task.isCancelled {
                // Finally disconnect if all attempts fail
                await cleanUp(withError: error)
            }
        }
    }
}

// MARK: - Session Migration

extension Room {
    func sendSyncState() async throws {
        guard let transport = _state.transport else {
            log("Transport is nil", .error)
            return
        }

        let (previousAnswer, previousOffer) = await transport.syncStateDescriptions()

        // 1. autosubscribe on, so subscribed tracks = all tracks - unsub tracks,
        //    in this case, we send unsub tracks, so server add all tracks to this
        //    subscribe pc and unsub special tracks from it.
        // 2. autosubscribe off, we send subscribed tracks.

        let autoSubscribe = _state.connectOptions.autoSubscribe
        // Use isDesired (subscription intent) instead of isSubscribed (actual state)
        // to avoid race condition during quick reconnect where tracks aren't attached yet.
        let trackSids = _state.remoteParticipants.values.flatMap { participant in
            participant._state.trackPublications.values
                .compactMap { $0 as? RemoteTrackPublication }
                .filter { $0.isDesired != autoSubscribe }
                .map(\.sid)
        }

        log("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids.map(\.stringValue)
            $0.participantTracks = []
            $0.subscribe = !autoSubscribe
        }

        try await signalClient.sendSyncState(answer: previousAnswer?.toPBType(offerId: 0),
                                             offer: previousOffer?.toPBType(offerId: 0),
                                             subscription: subscription,
                                             publishTracks: localParticipant.publishedTracksInfo(),
                                             dataChannels: publisherDataChannel.infos(),
                                             dataChannelReceiveStates: subscriberDataChannel.receiveStates())
    }
}

// MARK: - Private helpers

extension Room {
    func requirePublisher() throws -> Transport {
        guard let publisher = _state.transport?.publisher else {
            log("Publisher is nil", .error)
            throw LiveKitError(.invalidState, message: "Publisher is nil")
        }

        return publisher
    }
}
