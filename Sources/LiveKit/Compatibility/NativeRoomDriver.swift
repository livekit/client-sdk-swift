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

internal import LiveKitFFI
internal import LiveKitTransport
import Foundation

/// Removable v2 state/delegate adapter; FfiRoom owns connection, commands and teardown.
actor NativeRoomDriver {
    private var session: FfiRoom?
    private var cursor: NativeRoomEventCursor?
    private var eventLoop: AnyTaskCancellable?
    private var stateLoop: AnyTaskCancellable?
    private var projection: NativeRoomState?
    private struct RpcRegistration {
        let id = UUID()
        let handler: RpcHandler
    }

    private var handlers: [String: RpcRegistration] = [:]
    private var confirmedRpcMethods: Set<String> = []
    private let rpcOperations = SerialRunnerActor<Void>()
    private var closing = false
    private var reportedPacketMetadataGap = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var rpcTasks: [String: AnyTaskCancellable] = [:]

    init() { LiveKitTransport.initialize() }

    deinit {
        let session = session
        let cursor = cursor
        // UniFFI cancellation must not run synchronously on Swift's task cancellation stack.
        Task.detached {
            cursor?.cancel()
            session?.cancel()
        }
    }

    func connect(room: Room, url: String, token: String, connectOptions: ConnectOptions?, roomOptions: RoomOptions?) async throws {
        guard session == nil, !closing else {
            throw LiveKitError(.invalidState, message: "A native session is already active")
        }
        guard let parsed = URL(string: url), parsed.isValidForConnect else {
            throw LiveKitError(.failedToParseUrl)
        }
        let connect = connectOptions ?? room._state.connectOptions
        let options = roomOptions ?? room._state.roomOptions
        try Task.checkCancellation()
        let nativeOptions = try Self.options(connect, options)
        if let encryption = options.encryptionOptions {
            room.nativeE2EE.mutate { $0 = E2EEManager(options: encryption) }
        } else if let encryption = options.e2eeOptions {
            room.nativeE2EE.mutate { $0 = E2EEManager(e2eeOptions: encryption) }
        }
        try Task.checkCancellation()
        let native = FfiRoom()
        let events = native.events(options: .init())
        session = native
        reportedPacketMetadataGap = false
        cursor = events
        room.nativeRoom.mutate { $0 = native }
        room._state.mutate {
            $0.connectOptions = connect
            $0.roomOptions = options
            $0.providedUrl = parsed
            $0.token = token
            $0.connectionState = .connecting
        }
        do {
            let connected = try await cancellingNative({ native.cancel() }) {
                try await native.connect(url: url, token: token, options: nativeOptions)
            }
            let snapshot = try await initialState(native, connected: connected)
            try Task.checkCancellation()
            guard session === native, !closing else { throw CancellationError() }
            projection = snapshot
            await room.applyNativeSnapshot(snapshot, restoreDataTracks: true)
            guard session === native, !closing else { throw CancellationError() }
            try await synchronizeRpcMethods(on: native)
            guard session === native, !closing else { throw CancellationError() }
            room._state.mutate { $0.connectedUrl = parsed; $0.connectionState = .connected }
            await room.applyNativeMedia(snapshot)
            guard session === native, !closing else { throw CancellationError() }
            startEvents(events, session: native, room: room)
            startStateObservation(native, room: room)
        } catch {
            if session === native, !closing { await disconnect(room: room, error: error) }
            throw LiveKitError.from(error: error) ?? LiveKitError(.invalidState, message: String(describing: error))
        }
    }

    func disconnect(room: Room, error: Error? = nil) async {
        if closing {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        guard let native = session else { return }
        closing = true
        room.nativeRoom.mutate { $0 = nil }
        room._state.mutate { if $0.connectionState != .connecting { $0.connectionState = .disconnecting } }
        eventLoop = nil
        stateLoop = nil
        rpcTasks.removeAll()
        let events = cursor
        await Task.detached { events?.cancel() }.value
        var disconnectError = error
        do {
            try await native.disconnect()
        } catch {
            // Rust retains the driver until actual teardown, even after its wait times out.
            room.log("Native room cleanup has not completed: \(error)", .warning)
            disconnectError = disconnectError ?? LiveKitError.mappingNative(error)
        }
        await room.resetNativeState(error: disconnectError)
        session = nil
        cursor = nil
        projection = nil
        confirmedRpcMethods.removeAll()
        closing = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func startStateObservation(_ native: FfiRoom, room: Room) {
        stateLoop = native.states.subscribe(self) { [weak room] driver, state in
            guard let room else { return }
            await driver.receiveRoomValues(state.values, native: native, room: room)
        } onFailure: { [weak room] _, error in
            room?.log("Native state observation ended: \(error)", .warning)
        }
    }

    private func receiveRoomValues(_ values: NativeRoomValues, native: FfiRoom, room: Room) {
        guard session === native, !closing, var info = values.room, projection != nil else { return }
        // Metadata and connection transitions remain event-owned for v2 delegates.
        // Other room values no longer depend on RoomUpdated delta events.
        info.metadata = projection?.room?.metadata ?? info.metadata
        guard info != projection?.room else { return }
        projection?.room = info
        room.applyNativeRoomValues(info)
    }

    private func startEvents(_ events: NativeRoomEventCursor, session native: FfiRoom, room: Room) {
        cursor = events
        // events() replaces the session's previous cursor; this loop owns this cursor only.
        eventLoop = Task { [weak self, weak room] in
            var failure: Error?
            do {
                for try await update in Pull({ try await events.next() }, cancel: { events.cancel() }) {
                    guard let self, let room else { break }
                    await receive(update, session: native, room: room)
                }
            } catch {
                failure = error
            }
            // Also close on EOF or early exit. Join outside Swift's cancellation handler lock.
            await Task.detached { events.cancel() }.value
            if let failure, !Task.isCancelled, let self, let room {
                await eventFailure(failure, session: native, room: room)
            }
        }.cancellable()
    }

    private func eventFailure(_ error: Error, session native: FfiRoom, room: Room) async {
        guard session === native, !closing else { return }
        if case FfiRoomError.Overflow = error {
            let replacement = native.events(options: .init())
            let snapshot = NativeRoomState(replacement.startState())
            projection = snapshot
            await room.applyNativeSnapshot(snapshot, restoreDataTracks: true, restoreMedia: true)
            guard session === native, !closing else { return }
            startEvents(replacement, session: native, room: room)
        } else {
            await disconnect(room: room, error: error)
        }
    }

    private func receiveTransient(_ event: NativeRoomEvent, room: Room) -> Bool {
        // Transient packets are not represented by snapshots, even when their revision precedes it.
        switch event {
        case let .dataReceived(packet):
            #warning("TODO: Preserve per-packet encryption metadata in native data events")
            if !reportedPacketMetadataGap {
                reportedPacketMetadataGap = true
                room.log("Native packets omit encryption metadata; the legacy delegate encryption field is not authoritative", .warning)
            }
            room.didReceive(data: packet.payload, topic: packet.topic ?? "", participantIdentity: packet.participant?.identity() ?? "")
            return true
        case let .byteStreamOpened(reader, identity):
            room.dataStreams.handleByteStreamOpened(reader, identity: identity)
            return true
        case let .textStreamOpened(reader, identity):
            room.dataStreams.handleTextStreamOpened(reader, identity: identity)
            return true
        case let .rpcRequested(invocation):
            handleRpc(invocation)
            return true
        case let .dataTrackPublished(track, identity):
            room.nativeDataTrackPublished(track, identity: identity)
            return true
        case let .dataTrackUnpublished(_, identity, sid):
            room.nativeDataTrackUnpublished(sid: sid, identity: identity)
            return true
        case .dtmfReceived: return true // The public Swift API has no DTMF receive callback.
        case .roomUpdated: return true // Authoritative room observation replaces this state-only delta.
        default: return false
        }
    }

    // This projection preserves v2 ordered delegate transitions and membership.
    // Coalescing observations cannot replace it: an A→B→A name change must still
    // deliver both event-owned values. Core values come from immutable observations.
    // swiftlint:disable:next cyclomatic_complexity
    private func receive(_ update: NativeRoomUpdate, session native: FfiRoom, room: Room) async {
        guard session === native, !closing, var snapshot = projection else { return }
        if receiveTransient(update.event, room: room) { return }
        guard update.revision > snapshot.revision else { return }
        snapshot.revision = update.revision
        var mediaChanged = false
        switch update.event {
        case let .connectionStateChanged(state): snapshot.connection = state
        case let .disconnected(reason):
            await disconnect(room: room, error: reason == .clientInitiated ? nil : LiveKitError(reason.lkErrorType))
            return
        case let .roomMetadataChanged(info, _): snapshot.room?.metadata = info.metadata
        case let .roomMoved(info): snapshot.room = info
        case let .tokenRefreshed(token): room._state.mutate { $0.token = token }
        case let .participantDisconnected(participant):
            let participant = NativeParticipant(participant)
            snapshot.remoteParticipants.removeAll { $0.identity == participant.identity }
            snapshot.publications.removeAll { $0.participantIdentity == participant.identity }
        case let .trackPublished(publication), let .trackMuted(publication), let .trackUnmuted(publication),
             let .localTrackPublished(publication, _), let .trackSubscribed(publication, _), let .trackUnsubscribed(publication, _):
            let publication = NativeTrackPublication(publication)
            mediaChanged = true
            snapshot.publications.removeAll { $0.sid == publication.sid }
            snapshot.publications.append(publication)
        case let .trackUnpublished(publication):
            let publication = NativeTrackPublication(publication)
            mediaChanged = true
            snapshot.publications.removeAll { $0.sid == publication.sid }
        case let .localTrackRepublished(previous, publication, _):
            let publication = NativeTrackPublication(publication)
            mediaChanged = true
            snapshot.publications.removeAll { $0.sid == previous || $0.sid == publication.sid }
            snapshot.publications.append(publication)
        case let .activeSpeakersChanged(speakers):
            updateSpeakers(speakers, in: &snapshot, room: room)
            projection = snapshot
            return
        case let .trackSubscriptionFailed(ffiParticipant, sid, error):
            let identity = ffiParticipant.identity()
            if let participant = room.remoteParticipants[Participant.Identity(from: identity)] {
                room.delegates.notify { $0.room?(room, participant: participant, didFailToSubscribeTrackWithSid: Track.Sid(from: sid), error: LiveKitError(.invalidState, message: String(describing: error))) }
            }
        default: snapshot.applyParticipantEvent(update.event)
        }
        projection = snapshot
        await room.applyNativeSnapshot(snapshot, restoreMedia: mediaChanged)
    }

    private func updateSpeakers(_ speakers: [FfiParticipant], in snapshot: inout NativeRoomState, room: Room) {
        let levels = Dictionary(speakers.map { ($0.identity(), $0.audioLevel()) }, uniquingKeysWith: { _, newest in newest })
        let localIdentity = snapshot.localParticipant?.identity ?? ""
        snapshot.localParticipant?.audioLevel = levels[localIdentity] ?? 0
        snapshot.localParticipant?.isSpeaking = levels[localIdentity] != nil
        for index in snapshot.remoteParticipants.indices {
            let identity = snapshot.remoteParticipants[index].identity
            snapshot.remoteParticipants[index].audioLevel = levels[identity] ?? 0
            snapshot.remoteParticipants[index].isSpeaking = levels[identity] != nil
        }
        room.didUpdateSpeakers(speakers.compactMap { speaker in
            let participant: Participant? = room.localParticipant.identity?.stringValue == speaker.identity()
                ? room.localParticipant : room.remoteParticipants[Participant.Identity(from: speaker.identity())]
            return participant.map { ($0, speaker.audioLevel()) }
        })
    }
}

extension NativeRoomDriver {
    private func initialState(_ native: FfiRoom, connected: FfiRoomState) async throws -> NativeRoomState {
        var states = native.states.makeAsyncIterator()
        guard let initial = try await states.next() else { throw CancellationError() }
        // Keep the ordered cursor's membership baseline. Child values are owned
        // observations, and room values come from the authoritative state stream.
        var snapshot = NativeRoomState(connected)
        if var info = initial.values.room {
            info.metadata = snapshot.room?.metadata ?? info.metadata
            snapshot.room = info
        }
        return snapshot
    }

    func registerRpcMethod(_ method: String, handler: @escaping RpcHandler) async throws {
        guard handlers[method] == nil else { throw LiveKitError(.invalidState, message: "RPC handler already registered") }
        let registration = RpcRegistration(handler: handler)
        handlers[method] = registration
        guard let session, projection != nil, !closing else { return }
        do {
            try await synchronizeRpcMethods(on: session)
        } catch {
            if handlers[method]?.id == registration.id { handlers[method] = nil }
            throw LiveKitError.mappingNative(error)
        }
    }

    func unregisterRpcMethod(_ method: String) async {
        handlers[method] = nil
        guard let session, projection != nil, !closing else { return }
        try? await synchronizeRpcMethods(on: session)
    }

    private func synchronizeRpcMethods(on native: FfiRoom) async throws {
        try await rpcOperations.run { try await self.reconcileRpcMethods(on: native) }
    }

    private func reconcileRpcMethods(on native: FfiRoom) async throws {
        while session === native, !closing, projection != nil {
            if let method = confirmedRpcMethods.first(where: { handlers[$0] == nil }) {
                do {
                    try await native.unregisterRpcMethod(method: method)
                } catch {
                    Room.log("Native RPC unregister was not confirmed: \(error)", .warning)
                }
                guard session === native, !closing else { return }
                // Swift rejects residual handlers after failed removal; re-registering replaces the core handler and needs a fresh ack.
                confirmedRpcMethods.remove(method)
            } else if let (method, registration) = handlers.first(where: { !confirmedRpcMethods.contains($0.key) }) {
                do {
                    try await native.registerRpcMethod(method: method)
                } catch {
                    if handlers[method]?.id == registration.id { handlers[method] = nil }
                    throw LiveKitError.mappingNative(error)
                }
                guard session === native, !closing else { return }
                confirmedRpcMethods.insert(method)
            } else { return }
        }
    }

    func isRpcMethodRegistered(_ method: String) -> Bool { handlers[method] != nil }

    func performRpc(destinationIdentity: Participant.Identity, method: String, payload: String,
                    responseTimeout: TimeInterval, maxRoundTripLatency: TimeInterval) async throws -> String
    {
        guard let session, !closing else { throw RpcError.builtIn(.sendFailed) }
        let latency = try Self.milliseconds(maxRoundTripLatency)
        let timeout = try Self.milliseconds(max(responseTimeout, maxRoundTripLatency + 1))
        guard let timeout = UInt32(exactly: timeout), let latency = UInt32(exactly: latency) else {
            throw LiveKitError(.invalidParameter, message: "RPC timeout exceeds native UInt32 range")
        }
        do {
            return try await abandoningOnCancel {
                try await session.performRpc(options: .init(destinationIdentity: destinationIdentity.stringValue,
                                                            method: method, payload: payload,
                                                            responseTimeoutMs: timeout, maxRoundTripLatencyMs: latency))
            }
        } catch let NativeRpcError.Failed(code, reason, data) {
            throw RpcError(code: Int(code), message: reason, data: data ?? "")
        }
    }

    private func handleRpc(_ invocation: NativeRpcInvocation) {
        let info = invocation.info()
        guard let handler = handlers[info.method]?.handler else {
            _ = invocation.reject(error: .Failed(code: 1400, reason: "Unsupported method", data: nil))
            return
        }
        rpcTasks[info.requestId] = Task { [weak self] in
            do {
                let response = try await handler(.init(requestId: info.requestId, callerIdentity: .init(from: info.callerIdentity),
                                                       payload: info.payload, responseTimeout: Double(info.responseTimeoutMs) / 1000))
                _ = invocation.respond(payload: response)
            } catch {
                let rpc = error as? RpcError ?? .builtIn(.applicationError)
                _ = invocation.reject(error: .Failed(code: UInt32(clamping: rpc.code), reason: rpc.message, data: rpc.data))
            }
            await self?.finishRpc(info.requestId)
        }.cancellable()
    }

    private func finishRpc(_ id: String) { rpcTasks[id] = nil }
}
