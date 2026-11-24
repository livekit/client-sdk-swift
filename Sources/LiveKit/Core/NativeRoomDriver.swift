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
import Foundation

/// Owns the native lifecycle and ordered event projection. Public getters remain in Room.StateSync.
actor NativeRoomDriver {
    private var session: NativeRoomSession?
    private var cursor: NativeRoomEventCursor?
    private var eventLoop: AnyTaskCancellable?
    private var projection: NativeRoomState?
    private var handlers: [String: RpcHandler] = [:]
    private var closing = false
    private var reportedPacketMetadataGap = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var rpcTasks: [String: AnyTaskCancellable] = [:]

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
        let native = NativeRoomSession()
        let events = native.events(options: .init())
        session = native
        reportedPacketMetadataGap = false
        cursor = events
        room.nativeSession.mutate { $0 = native }
        room._state.mutate {
            $0.connectOptions = connect
            $0.roomOptions = options
            $0.providedUrl = parsed
            $0.token = token
            $0.connectionState = .connecting
        }
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await abandoningOnCancel { try await native.connect(url: url, token: token, options: nativeOptions) }
            } onCancel: {
                Task.detached { native.cancel() }
            }
            try Task.checkCancellation()
            guard session === native, !closing else { throw CancellationError() }
            projection = snapshot
            await room.applyNativeSnapshot(snapshot, restoreDataTracks: true)
            guard session === native, !closing else { throw CancellationError() }
            for method in handlers.keys {
                try await native.registerRpcMethod(method: method)
            }
            guard session === native, !closing else { throw CancellationError() }
            room._state.mutate { $0.connectedUrl = parsed; $0.connectionState = .connected }
            startEvents(events, session: native, room: room)
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
        room.nativeSession.mutate { $0 = nil }
        room._state.mutate { if $0.connectionState != .connecting { $0.connectionState = .disconnecting } }
        eventLoop = nil
        rpcTasks.removeAll()
        let events = cursor
        await Task.detached { events?.cancel() }.value
        await native.disconnect()
        await room.resetNativeState(error: error)
        session = nil
        cursor = nil
        projection = nil
        closing = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func startEvents(_ events: NativeRoomEventCursor, session native: NativeRoomSession, room: Room) {
        cursor = events
        eventLoop = Task { [weak self, weak room] in
            do {
                try await withTaskCancellationHandler {
                    while !Task.isCancelled, let update = try await events.next() {
                        guard let self, let room else { return }
                        await self.receive(update, session: native, room: room)
                    }
                } onCancel: {
                    Task.detached { events.cancel() }
                }
            } catch {
                guard !Task.isCancelled, let self, let room else { return }
                await eventFailure(error, session: native, room: room)
            }
        }.cancellable()
    }

    private func eventFailure(_ error: Error, session native: NativeRoomSession, room: Room) async {
        guard session === native, !closing else { return }
        if case NativeSessionError.Overflow = error {
            let replacement = native.events(options: .init())
            let snapshot = replacement.startState()
            projection = snapshot
            await room.applyNativeSnapshot(snapshot, restoreDataTracks: true)
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
            if !reportedPacketMetadataGap {
                reportedPacketMetadataGap = true
                room.log("Native packets omit encryption metadata; the legacy delegate encryption field is not authoritative", .warning)
            }
            room.engine(room, didReceiveUserPacket: .with { $0.payload = packet.payload; $0.topic = packet.topic ?? "" },
                        participantIdentity: packet.participantIdentity ?? "", encryptionType: .none)
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
        default: return false
        }
    }

    // The exhaustive state-event projection intentionally mirrors the native event enum.
    // swiftlint:disable:next cyclomatic_complexity
    private func receive(_ update: NativeRoomUpdate, session native: NativeRoomSession, room: Room) async {
        guard session === native, !closing, var snapshot = projection else { return }
        if receiveTransient(update.event, room: room) { return }
        guard update.revision > snapshot.revision else { return }
        snapshot.revision = update.revision
        switch update.event {
        case let .connectionStateChanged(state): snapshot.connection = state
        case let .disconnected(reason):
            await disconnect(room: room, error: reason == .clientInitiated ? nil : LiveKitError(.invalidState, message: "Native disconnect: \(reason)"))
            return
        case let .roomUpdated(info), let .roomMetadataChanged(info, _), let .roomMoved(info): snapshot.room = info
        case let .tokenRefreshed(token): room._state.mutate { $0.token = token }
        case let .participantConnected(participant), let .participantUpdated(participant),
             let .participantMetadataChanged(participant, _), let .participantNameChanged(participant, _),
             let .participantAttributesChanged(participant, _), let .participantPermissionChanged(participant),
             let .participantEncryptionStatusChanged(participant), let .connectionQualityChanged(participant):
            if participant.isLocal { snapshot.localParticipant = participant } else {
                snapshot.remoteParticipants.removeAll { $0.identity == participant.identity }
                snapshot.remoteParticipants.append(participant)
            }
        case let .participantDisconnected(participant):
            snapshot.remoteParticipants.removeAll { $0.identity == participant.identity }
            snapshot.publications.removeAll { $0.participantIdentity == participant.identity }
        case let .trackPublished(publication), let .trackMuted(publication), let .trackUnmuted(publication),
             let .trackSubscribed(publication), let .trackUnsubscribed(publication):
            snapshot.publications.removeAll { $0.sid == publication.sid }
            snapshot.publications.append(publication)
        case let .trackUnpublished(publication): snapshot.publications.removeAll { $0.sid == publication.sid }
        case let .localTrackRepublished(previous, publication):
            snapshot.publications.removeAll { $0.sid == previous || $0.sid == publication.sid }
            snapshot.publications.append(publication)
        case let .activeSpeakersChanged(speakers):
            updateSpeakers(speakers, in: &snapshot, room: room)
            projection = snapshot
            return
        case let .trackSubscriptionFailed(identity, sid, reason):
            if let participant = room.remoteParticipants[Participant.Identity(from: identity)] {
                room.delegates.notify { $0.room?(room, participant: participant, didFailToSubscribeTrackWithSid: Track.Sid(from: sid), error: LiveKitError(.invalidState, message: reason)) }
            }
        default: break
        }
        projection = snapshot
        await room.applyNativeSnapshot(snapshot)
    }

    private func updateSpeakers(_ speakers: [NativeSpeaker], in snapshot: inout NativeRoomState, room: Room) {
        let levels = Dictionary(speakers.map { ($0.identity, $0.audioLevel) }, uniquingKeysWith: { _, newest in newest })
        let localIdentity = snapshot.localParticipant?.identity ?? ""
        snapshot.localParticipant?.audioLevel = levels[localIdentity] ?? 0
        snapshot.localParticipant?.isSpeaking = levels[localIdentity] != nil
        for index in snapshot.remoteParticipants.indices {
            let identity = snapshot.remoteParticipants[index].identity
            snapshot.remoteParticipants[index].audioLevel = levels[identity] ?? 0
            snapshot.remoteParticipants[index].isSpeaking = levels[identity] != nil
        }
        room.engine(room, didUpdateSpeakers: speakers.compactMap { speaker in
            let participant: Participant? = room.localParticipant.identity?.stringValue == speaker.identity
                ? room.localParticipant : room.remoteParticipants[Participant.Identity(from: speaker.identity)]
            guard let sid = participant?.sid else { return nil }
            return .with { $0.sid = sid.stringValue; $0.level = speaker.audioLevel; $0.active = true }
        })
    }
}

extension NativeRoomDriver {
    func registerRpcMethod(_ method: String, handler: @escaping RpcHandler) async throws {
        guard handlers[method] == nil else { throw LiveKitError(.invalidState, message: "RPC handler already registered") }
        if let session, !closing { try await session.registerRpcMethod(method: method) }
        handlers[method] = handler
    }

    func unregisterRpcMethod(_ method: String) async {
        handlers[method] = nil
        if let session, !closing { try? await session.unregisterRpcMethod(method: method) }
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
        guard let handler = handlers[info.method] else {
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

extension NativeRoomDriver {
    private static func milliseconds(_ interval: TimeInterval) throws -> UInt64 {
        guard interval.isFinite, interval >= 0, interval * 1000 < Double(UInt64.max) else {
            throw LiveKitError(.invalidParameter, message: "Invalid timeout")
        }
        return UInt64(interval * 1000)
    }

    static func options(_ connect: ConnectOptions, _ room: RoomOptions) throws -> NativeConnectOptions {
        let defaults = ConnectOptions()
        guard connect.reconnectAttempts == defaults.reconnectAttempts,
              connect.reconnectAttemptDelay == defaults.reconnectAttemptDelay,
              connect.reconnectMaxDelay == defaults.reconnectMaxDelay,
              connect.primaryTransportConnectTimeout == defaults.primaryTransportConnectTimeout,
              connect.publisherTransportConnectTimeout == defaults.publisherTransportConnectTimeout,
              connect.iceTransportPolicy != .none,
              !connect.isDscpEnabled, !connect.enableMicrophone,
              connect.protocolVersion == defaults.protocolVersion, connect.clientProtocol == defaults.clientProtocol
        else {
            throw LiveKitError(.invalidParameter, message: "A nondefault connection/media/encryption option is not exported by the native session")
        }
        let payload = room.dataStreamOptions.maxPayloadByteLength
        guard payload == nil || UInt32(exactly: payload!) != nil else {
            throw LiveKitError(.invalidParameter, message: "Stream payload limit exceeds native UInt32 range")
        }
        let encryption: NativeEncryptionOptions?
        if let options = room.encryptionOptions {
            guard options.encryptionType == .gcm else { throw LiveKitError(.invalidParameter, message: "Only native AES-GCM is supported") }
            encryption = try .init(keyProvider: options.keyProvider.nativeProvider())
        } else if let options = room.e2eeOptions {
            guard options.encryptionType == .gcm else { throw LiveKitError(.invalidParameter, message: "Only native AES-GCM is supported") }
            encryption = try .init(keyProvider: options.keyProvider.nativeProvider(), legacyMediaOnly: true)
        } else { encryption = nil }
        return try .init(autoSubscribe: connect.autoSubscribe, adaptiveStream: room.adaptiveStream,
                         dynacast: room.dynacast, singlePeerConnection: room.singlePeerConnection,
                         connectTimeoutMs: milliseconds(connect.socketConnectTimeoutInterval),
                         sdk: "swift", sdkVersion: LiveKitSDK.version, maxStreamPayloadBytes: payload.map(UInt32.init), encryption: encryption,
                         iceServers: connect.iceServers.map { .init(urls: $0.urls, username: $0.username ?? "", password: $0.credential ?? "") },
                         iceTransportPolicy: connect.iceTransportPolicy == .relay ? .relay : connect.iceTransportPolicy == .noHost ? .noHost : .all,
                         clientProtocol: Int32(connect.clientProtocol.rawValue))
    }
}
