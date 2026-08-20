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

import Foundation

internal import LiveKitUniFFI

// MARK: - DataStreams

/// Owns the incoming/outgoing UniFFI data stream managers and the topic→handler registry, and
/// routes Room/participant calls to the right manager. The ``Room`` holds a single reference,
/// keeping the subsystem off the Room's surface.
///
/// Unlike ``DataTracks``, this subsystem is **Room-scoped, not session-scoped**: stream handlers
/// (registered by the app, and by internal RPC/transcription wiring) must survive reconnects and be
/// registrable before connect, so the registry lives here for the Room's lifetime. The FFI managers
/// hold no channel handles — inbound packets are pushed in via ``handleIncoming(_:)`` and outbound
/// packets are pulled out via the delegate — so they too live for the whole Room.
///
/// `@unchecked Sendable`: the only mutable state is the StateSync-guarded registry; the managers and
/// delegates are immutable after init. Not an actor — the UniFFI delegate callbacks are synchronous
/// and can't `await`.
final class DataStreams: NSObject, @unchecked Sendable, Loggable {
    private let outgoing: LiveKitUniFFI.OutgoingDataStreamManager

    // Created lazily on the first inbound packet of a session, not at init: the incoming manager's
    // payload cap is fixed at construction (the FFI exposes no setter) and comes from the room's
    // options, which aren't finalized until `connect` — after this coordinator is built at
    // `Room.init`. Deferring lets it pick up a `maxPayloadByteLength` passed at connect time, and
    // `reset()` drops it at teardown so the *next* connect re-reads the cap rather than inheriting
    // the first session's. StateSync-guarded so it's constructed exactly once even if packets race in.
    private let _incoming = StateSync<LiveKitUniFFI.IncomingDataStreamManager?>(nil)

    // Held weakly: the Room owns this coordinator, so the back-reference must not retain it. Used
    // for the room-level encryption type stamped onto stream info, and for logging.
    private weak var room: Room?

    // The Swift-side handler registry. The FFI reports every opened stream regardless of topic
    // (`onByteStreamOpened`/`onTextStreamOpened`); we route by `info.topic` to these handlers.
    private let byteStreamHandlers = StateSync<[String: ByteStreamHandler]>([:])
    private let textStreamHandlers = StateSync<[String: TextStreamHandler]>([:])
    // Topics we've already logged a missing-handler warning for, to avoid log spam.
    private let failedTopics = StateSync<Set<String>>([])
    // Topics whose text handlers run in wire order. Used by internal consumers like transcription;
    // off by default so concurrent consumers (e.g. RPC) aren't slowed.
    private let orderedTopics = StateSync<Set<String>>([])

    // Ordering is a wire *happens-before* relation: a stream that opened after another one closed
    // must have its handler run after that one's. Streams that overlap on the wire are concurrent
    // and must not delay each other — a live transcript arriving while an earlier message stream is
    // still open has to be delivered immediately.
    //
    // So a newly opened stream waits on `finishingHandlers` — handlers whose stream has already
    // closed but which haven't returned yet — and *not* on handlers of streams that are still open.
    // `runningHandlers` holds the latter until the FFI reports the close, at which point the entry
    // moves across. Both are keyed by stream id within a topic, and entries are removed when the
    // handler returns, so neither grows without bound.
    private let runningHandlers = StateSync<[String: [String: Task<Void, Never>]]>([:])
    private let finishingHandlers = StateSync<[String: [String: Task<Void, Never>]]>([:])
    // Stream id -> topic, so a close event (which carries no topic) can find its queue.
    private let streamTopics = StateSync<[String: String]>([:])

    init(room: Room) {
        self.room = room
        let outgoingDelegate = OutgoingDelegate(room: room)
        let registry = Registry(room: room)
        outgoing = LiveKitUniFFI.OutgoingDataStreamManager(delegate: outgoingDelegate, registry: registry)
        super.init()
    }

    /// The incoming manager, created on first use with the room's current payload cap. Topic routing
    /// (incl. the `lk.rpc` guard) is handled Swift-side in `Room+DataStream`.
    private func incomingManager() -> LiveKitUniFFI.IncomingDataStreamManager {
        // Fast path: after the first packet of a session this is a plain read, keeping the exclusive
        // lock off the per-packet inbound path. `mutate` re-checks, so the race is still safe.
        if let existing = _incoming.copy() { return existing }
        return _incoming.mutate { existing in
            if let existing { return existing }
            let delegate = IncomingDelegate()
            delegate.coordinator = self
            // `nil` → the core's default cap. Read now (first packet, i.e. post-connect) so a
            // `maxPayloadByteLength` supplied via `connect(roomOptions:)` is honored.
            // `DataStreamOptions` normalizes non-positive values to `nil`, so the conversion below
            // can't trap.
            let maxPayloadByteLength = room?._state.roomOptions.dataStreamOptions.maxPayloadByteLength
            let manager = LiveKitUniFFI.IncomingDataStreamManager(
                delegate: delegate,
                maxPayloadByteLength: maxPayloadByteLength.map { UInt64($0) },
            )
            existing = manager
            return manager
        }
    }

    // Encryption type for *outgoing* stream info. Inbound infos carry the real per-packet value
    // reported by the FFI, which `handleIncoming` now supplies; there is no equivalent signal for a
    // stream we're sending, so the room's data-channel setting is the accurate answer there.
    private var currentEncryptionType: EncryptionType {
        room?.e2eeManager?.dataChannelEncryptionType ?? .none
    }

    // MARK: - Handler registration

    func registerByteStreamHandler(for topic: String, _ onNewStream: @escaping ByteStreamHandler) throws {
        try byteStreamHandlers.mutate {
            guard $0[topic] == nil else { throw StreamError.handlerAlreadyRegistered }
            $0[topic] = onNewStream
        }
    }

    /// When `ordered` is true, successive streams on `topic` have their handlers run in wire order:
    /// a handler for a stream that opened after another finishes only once the earlier handler
    /// returns. Off by default — it would serialize consumers that want strict concurrency (e.g. RPC).
    func registerTextStreamHandler(for topic: String, ordered: Bool = false, _ onNewStream: @escaping TextStreamHandler) throws {
        try textStreamHandlers.mutate {
            guard $0[topic] == nil else { throw StreamError.handlerAlreadyRegistered }
            $0[topic] = onNewStream
        }
        if ordered { orderedTopics.mutate { $0.insert(topic) } }
    }

    /// SDK-internal: register `onNewStream` for `topic` if no handler is registered yet, otherwise
    /// no-op. Used by idempotent wiring paths (e.g. RPC v2 setup runs on every connect) that don't
    /// want the duplicate-registration throw from the public API.
    @discardableResult
    func registerTextStreamHandlerIfNeeded(for topic: String, _ onNewStream: @escaping TextStreamHandler) -> Bool {
        textStreamHandlers.mutate {
            guard $0[topic] == nil else { return false }
            $0[topic] = onNewStream
            return true
        }
    }

    func unregisterByteStreamHandler(for topic: String) {
        byteStreamHandlers.mutate { $0[topic] = nil }
    }

    func unregisterTextStreamHandler(for topic: String) {
        textStreamHandlers.mutate { $0[topic] = nil }
        orderedTopics.mutate { $0.remove(topic) }
        runningHandlers.mutate { $0[topic] = nil }
        finishingHandlers.mutate { $0[topic] = nil }
    }

    // MARK: - Sending

    func sendText(_ text: String, options: StreamTextOptions) async throws -> TextStreamInfo {
        try await mappingErrors {
            let info = try await outgoing.sendText(text: text, options: options.ffi)
            return TextStreamInfo(info, encryptionType: currentEncryptionType)
        }
    }

    func sendFile(_ fileURL: URL, options: StreamByteOptions) async throws -> ByteStreamInfo {
        // The FFI reads the file's bytes but doesn't infer its metadata, so resolve name/MIME/size
        // from disk here (matching the previous implementation) unless the caller set them.
        guard let fileInfo = FileInfo(for: fileURL) else {
            throw StreamError.fileInfoUnavailable
        }
        let ffiOptions = LiveKitUniFFI.StreamByteOptions(
            topic: options.topic,
            attributes: options.attributes,
            destinationIdentities: options.destinationIdentities.map(\.stringValue),
            id: options.id,
            mimeType: options.mimeType ?? fileInfo.mimeType,
            name: options.name ?? fileInfo.name,
            totalLength: UInt64(fileInfo.size),
            compress: options.compress,
            senderIdentity: nil,
        )
        return try await mappingErrors {
            let info = try await outgoing.sendFile(path: fileURL.path, options: ffiOptions)
            return ByteStreamInfo(info, encryptionType: currentEncryptionType)
        }
    }

    func streamText(options: StreamTextOptions) async throws -> TextStreamWriter {
        try await mappingErrors {
            let writer = try await outgoing.streamText(options: options.ffi)
            return TextStreamWriter(writer, encryptionType: currentEncryptionType)
        }
    }

    func streamBytes(options: StreamByteOptions) async throws -> ByteStreamWriter {
        try await mappingErrors {
            let writer = try await outgoing.streamBytes(options: options.ffi)
            return ByteStreamWriter(writer, encryptionType: currentEncryptionType)
        }
    }

    // MARK: - Incoming packets

    /// Feeds a received data-stream packet (already decrypted and deduped by `DataChannelPair`) to
    /// the incoming manager. The FFI re-decodes the serialized `DataPacket` itself.
    ///
    /// `encryptionType` is passed separately because decryption consumes the packet field that
    /// carried it; the core compares it against the stream's header to reject a sender that mixes
    /// encrypted and plaintext frames within one stream.
    func handleIncoming(_ dataPacket: Livekit_DataPacket, encryptionType: EncryptionType) {
        guard let data = try? dataPacket.serializedData() else { return }
        incomingManager().handlePacketReceived(packet: data, encryptionType: encryptionType.ffiValue)
    }

    /// Number of incoming streams currently open. Restores the introspection v1 exposed on its
    /// manager: it lets a caller wait for a stream's descriptor to actually register before driving
    /// the abort paths, rather than inferring it from a handler having been dispatched.
    func openStreamCount() async -> UInt64 {
        guard let manager = _incoming.copy() else { return 0 }
        return await manager.openStreamCount()
    }

    // MARK: - Stream lifecycle

    /// Fails all open incoming streams so their handlers return (e.g. on cleanup). A handler blocked
    /// on a reader that will never finish would otherwise stall its topic's ordered queue. Handler
    /// registrations survive, so streams arriving after a reconnect are still handled.
    ///
    /// The incoming manager itself is discarded, not just drained: its payload cap is immutable after
    /// construction, so a fresh one has to be built for the next session to honor that session's
    /// `maxPayloadByteLength`. It holds no handler state — that lives here — so this loses nothing.
    func reset() {
        // No-op if the incoming manager was never created (no packets received): nothing is open.
        let existing = _incoming.mutate { manager -> LiveKitUniFFI.IncomingDataStreamManager? in
            let current = manager
            manager = nil
            return current
        }
        // Aborted through the reference taken above, so open readers still error out even though the
        // manager is no longer reachable from `_incoming`.
        existing?.abortAllStreams()
    }

    /// Fails open incoming streams sent by `identity` (they disconnected mid-send), so their readers
    /// throw and their handlers return instead of hanging.
    func closeStreams(from identity: Participant.Identity) {
        _incoming.copy()?.abortStreamsFrom(identity: identity.stringValue)
    }

    // MARK: - Stream open dispatch (called from the incoming delegate)

    func handleByteStreamOpened(_ ffiReader: LiveKitUniFFI.ByteStreamReader, identity: String) {
        let ffiInfo = ffiReader.info()
        let info = ByteStreamInfo(ffiInfo, encryptionType: EncryptionType(ffiInfo.encryptionType))
        guard let handler = byteStreamHandlers.copy()[info.topic] else {
            logMissingHandler(topic: info.topic, id: info.id, identity: identity)
            return
        }
        let reader = ByteStreamReader(ffiReader, info: info)
        let participantIdentity = Participant.Identity(from: identity)
        Task.detachedDiscarding { try await handler(reader, participantIdentity) }
    }

    func handleTextStreamOpened(_ ffiReader: LiveKitUniFFI.TextStreamReader, identity: String) {
        let ffiInfo = ffiReader.info()
        let info = TextStreamInfo(ffiInfo, encryptionType: EncryptionType(ffiInfo.encryptionType))
        guard let handler = textStreamHandlers.copy()[info.topic] else {
            logMissingHandler(topic: info.topic, id: info.id, identity: identity)
            return
        }
        let reader = TextStreamReader(ffiReader, info: info)
        let participantIdentity = Participant.Identity(from: identity)
        let topic = info.topic
        guard orderedTopics.copy().contains(topic) else {
            Task.detachedDiscarding { try await handler(reader, participantIdentity) }
            return
        }
        // Ordered topic. Wait only on handlers whose streams have already closed: this stream opened
        // after they ended, so it comes after them on the wire. Streams still open right now overlap
        // with this one and must not gate it.
        let streamID = info.id
        streamTopics.mutate { $0[streamID] = topic }
        let predecessors = Array(finishingHandlers.copy()[topic]?.values ?? [:].values)
        runningHandlers.mutate { running in
            running[topic, default: [:]][streamID] = Task.detached { [weak self] in
                for predecessor in predecessors {
                    await predecessor.value
                }
                do {
                    try await handler(reader, participantIdentity)
                } catch {
                    self?.log("Ordered text stream handler for topic '\(topic)' threw: \(error)", .warning)
                }
                self?.handlerCompleted(topic: topic, streamID: streamID)
            }
        }
    }

    /// The stream closed on the wire. Its handler may still be running, and until it returns it gates
    /// streams that open from now on — so move it out of `runningHandlers` and into the set later
    /// streams wait for.
    func handleStreamClosed(streamID: String, identity _: String) {
        guard let topic = streamTopics.copy()[streamID] else { return }
        guard let task = runningHandlers.mutate({ $0[topic]?.removeValue(forKey: streamID) }) else { return }
        finishingHandlers.mutate { $0[topic, default: [:]][streamID] = task }
    }

    /// Handler returned: it no longer gates anything, so drop it and stop tracking its stream.
    private func handlerCompleted(topic: String, streamID: String) {
        runningHandlers.mutate { $0[topic]?.removeValue(forKey: streamID) }
        finishingHandlers.mutate { $0[topic]?.removeValue(forKey: streamID) }
        streamTopics.mutate { $0[streamID] = nil }
    }

    private func logMissingHandler(topic: String, id: String, identity: String) {
        let shouldLog = failedTopics.mutate { $0.insert(topic).inserted }
        guard shouldLog else { return }
        log("Unable to find handler for incoming stream: \(id), topic: \(topic), opened by: \(identity)", .warning)
    }

    private func mappingErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as LiveKitUniFFI.DataStreamError {
            throw StreamError(error)
        }
    }
}
