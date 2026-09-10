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

/// Owns the outgoing UniFFI data stream manager and the topic→handler registry, and routes
/// Room/participant calls to the right manager. Staged as ``IdleDependencies``, the room-scoped
/// dependency tier, keeping the subsystem off the Room's surface.
///
/// Unlike ``DataTracks``, this subsystem is **Room-scoped, not session-scoped**: stream handlers
/// (registered by the app, and by internal RPC/transcription wiring) must survive reconnects and be
/// registrable before connect, so the registry lives here for the Room's lifetime. The outgoing
/// manager holds no channel handle — packets are pulled out of it via the delegate — and nothing
/// per-connection, so it lives here too. Its incoming counterpart does not: see ``incoming``.
///
/// `@unchecked Sendable`: the only mutable state is the StateSync-guarded registry and the
/// back-references ``attach(room:)`` fills in before the room can be shared; the managers and
/// delegates are immutable after init. Not an actor — the UniFFI delegate callbacks are synchronous
/// and can't `await`.
final class DataStreams: NSObject, @unchecked Sendable, Loggable {
    // Neither FFI manager is held here: both are owned by ``ConnectionDependencies`` and live
    // exactly as long as one connection. The incoming one because its payload cap is fixed at
    // construction (the FFI exposes no setter) from the options passed to `connect`; the outgoing
    // one so that dropping it at disconnect closes the writers opened on that session — their next
    // chunk would otherwise reach the *next* session, whose receivers never saw the header.
    //
    // Before connect and after disconnect there is neither, which is what a stream needs anyway:
    // a transport to travel on.
    private var incoming: LiveKitUniFFI.IncomingDataStreamManager? {
        room?._state.stage.connection?.incomingDataStreams
    }

    private func outgoing() throws -> LiveKitUniFFI.OutgoingDataStreamManager {
        guard let outgoing = room?._state.stage.connection?.outgoingDataStreams else {
            throw LiveKitError(.invalidState, message: "Room is not connected")
        }
        return outgoing
    }

    // Held weakly: the Room owns this coordinator, so the back-reference must not retain it. Used
    // for the room-level encryption type stamped onto stream info, and for logging.
    private weak var room: Room?

    // The Swift-side handler registry. The FFI reports every opened stream regardless of topic
    // (`onByteStreamOpened`/`onTextStreamOpened`); we route by `info.topic` to these handlers.
    private let byteStreamHandlers = StateSync<[String: ByteStreamHandler]>([:])
    // Handler and ordering policy in one entry: dispatch resolves both from a single read, so a
    // stream can't open between them and take the unordered path on an ordered topic.
    private struct TextEntry {
        let handler: TextStreamHandler
        let isOrdered: Bool
    }

    private let textStreamHandlers = StateSync<[String: TextEntry]>([:])
    // Topics we've already logged a missing-handler warning for, to avoid log spam.
    private let failedTopics = StateSync<Set<String>>([])

    // Ordering is a wire *happens-before* relation: a stream that opened after another one closed
    // must have its handler run after that one's. Streams that overlap on the wire are concurrent
    // and must not delay each other — a live transcript arriving while an earlier message stream is
    // still open has to be delivered immediately.
    //
    // So a newly opened stream waits on `finishing` — handlers whose stream has already closed but
    // which haven't returned yet — and *not* on handlers of streams that are still open. `running`
    // holds the latter until the FFI reports the close, at which point the entry moves across.
    // Entries are removed when the handler returns, so neither map grows without bound.
    //
    // One lock for all of it: an open reads `finishing` and writes `running` + `openStreams`, a
    // close moves an entry between the first two, and a completion clears all three — they have to
    // agree.
    private struct OrderedHandlers {
        /// Which entry a close event should move, by the stream id the sender chose.
        struct OpenStream {
            let topic: String
            let token: UInt64
        }

        // Keyed by a token unique to the handler, not by stream id: nothing stops a sender from
        // reusing an id, and a successor must neither evict its predecessor's entry nor be evicted
        // by the predecessor's completion.
        var running: [String: [UInt64: Task<Void, Never>]] = [:]
        var finishing: [String: [UInt64: Task<Void, Never>]] = [:]
        var openStreams: [String: OpenStream] = [:]
        private var nextToken: UInt64 = 0

        mutating func makeToken() -> UInt64 {
            defer { nextToken &+= 1 }
            return nextToken
        }

        mutating func removeTopic(_ topic: String) {
            running[topic] = nil
            finishing[topic] = nil
            openStreams = openStreams.filter { $0.value.topic != topic }
        }
    }

    private let ordered = StateSync(OrderedHandlers())

    /// Supplies the back-reference, in `Room.init`'s second phase.
    ///
    /// Split from `init` because this subsystem is staged inside `Room.State` — built in the first
    /// phase, where `self` isn't available yet. Nothing can reach the room, and so nothing can reach
    /// this reference, until its initializer returns.
    func attach(room: Room) {
        self.room = room
    }

    /// Builds the connection-scoped incoming manager, wired back to this coordinator for stream
    /// dispatch. Called by ``ConnectionDependencies`` — topic routing (incl. the `lk.rpc` guard) is
    /// handled Swift-side here, so the manager itself carries no handler state.
    ///
    /// - Parameter maxPayloadByteLength: `nil` → the core's default cap. `DataStreamOptions`
    ///   normalizes non-positive values to `nil`, so the conversion below can't trap.
    static func makeIncomingManager(coordinator: DataStreams, maxPayloadByteLength: Int?) -> LiveKitUniFFI.IncomingDataStreamManager {
        let delegate = IncomingDelegate()
        delegate.coordinator = coordinator
        return LiveKitUniFFI.IncomingDataStreamManager(
            delegate: delegate,
            maxPayloadByteLength: maxPayloadByteLength.map { UInt64($0) },
        )
    }

    /// Builds the connection-scoped outgoing manager. Called by ``ConnectionDependencies``; when it
    /// is released the FFI cancels the task draining its packets, so writers left open on the
    /// retired session fail their next write instead of emitting into the next one.
    static func makeOutgoingManager(room: Room) -> LiveKitUniFFI.OutgoingDataStreamManager {
        LiveKitUniFFI.OutgoingDataStreamManager(delegate: OutgoingDelegate(room: room), registry: Registry(room: room))
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
            $0[topic] = TextEntry(handler: onNewStream, isOrdered: ordered)
        }
    }

    /// SDK-internal: register `onNewStream` for `topic` if no handler is registered yet, otherwise
    /// no-op. Used by idempotent wiring paths (e.g. RPC v2 setup runs on every connect) that don't
    /// want the duplicate-registration throw from the public API.
    @discardableResult
    func registerTextStreamHandlerIfNeeded(for topic: String, _ onNewStream: @escaping TextStreamHandler) -> Bool {
        textStreamHandlers.mutate {
            guard $0[topic] == nil else { return false }
            $0[topic] = TextEntry(handler: onNewStream, isOrdered: false)
            return true
        }
    }

    func unregisterByteStreamHandler(for topic: String) {
        byteStreamHandlers.mutate { $0[topic] = nil }
    }

    func unregisterTextStreamHandler(for topic: String) {
        textStreamHandlers.mutate { $0[topic] = nil }
        ordered.mutate { $0.removeTopic(topic) }
    }

    // MARK: - Sending

    func sendText(_ text: String, options: StreamTextOptions) async throws -> TextStreamInfo {
        try await mappingErrors {
            let info = try await outgoing().sendText(text: text, options: options.ffi)
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
            let info = try await outgoing().sendFile(path: fileURL.path, options: ffiOptions)
            return ByteStreamInfo(info, encryptionType: currentEncryptionType)
        }
    }

    func streamText(options: StreamTextOptions) async throws -> TextStreamWriter {
        try await mappingErrors {
            let writer = try await outgoing().streamText(options: options.ffi)
            return TextStreamWriter(writer, encryptionType: currentEncryptionType)
        }
    }

    func streamBytes(options: StreamByteOptions) async throws -> ByteStreamWriter {
        try await mappingErrors {
            let writer = try await outgoing().streamBytes(options: options.ffi)
            return ByteStreamWriter(writer, encryptionType: currentEncryptionType)
        }
    }

    // MARK: - Incoming packets

    /// Feeds a received data-stream packet (already decrypted and deduped by `DataChannelPair`) to
    /// the incoming manager. The core takes the wire form and decodes the header/chunk/trailer
    /// itself, so `serialized` — the bytes the packet was decoded from — is reused when it still
    /// describes the packet, and re-encoded only when decryption has rebuilt it.
    ///
    /// `encryptionType` is passed separately because decryption consumes the packet field that
    /// carried it; the core compares it against the stream's header to reject a sender that mixes
    /// encrypted and plaintext frames within one stream.
    func handleIncoming(_ dataPacket: Livekit_DataPacket, serialized: Data?, encryptionType: EncryptionType) {
        guard let incoming, let data = try? serialized ?? dataPacket.serializedData() else { return }
        incoming.handlePacketReceived(packet: data, encryptionType: encryptionType.ffiValue)
    }

    /// Number of incoming streams currently open. Restores the introspection v1 exposed on its
    /// manager: it lets a caller wait for a stream's descriptor to actually register before driving
    /// the abort paths, rather than inferring it from a handler having been dispatched.
    func openStreamCount() async -> UInt64 {
        guard let incoming else { return 0 }
        return await incoming.openStreamCount()
    }

    // MARK: - Stream lifecycle

    /// Fails all open incoming streams so their handlers return (e.g. on cleanup). A handler blocked
    /// on a reader that will never finish would otherwise stall its topic's ordered queue. Handler
    /// registrations survive, so streams arriving after a reconnect are still handled.
    ///
    /// The manager survives: a full reconnect keeps the connection it belongs to, and a disconnect
    /// releases it along with that connection — so the next connect always gets one built from that
    /// connection's `maxPayloadByteLength`.
    func reset() {
        incoming?.abortAllStreams()
    }

    /// Fails open incoming streams sent by `identity` (they disconnected mid-send), so their readers
    /// throw and their handlers return instead of hanging.
    func closeStreams(from identity: Participant.Identity) {
        incoming?.abortStreamsFrom(identity: identity.stringValue)
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
        guard let entry = textStreamHandlers.copy()[info.topic] else {
            logMissingHandler(topic: info.topic, id: info.id, identity: identity)
            return
        }
        let handler = entry.handler
        let reader = TextStreamReader(ffiReader, info: info)
        let participantIdentity = Participant.Identity(from: identity)
        let topic = info.topic
        guard entry.isOrdered else {
            Task.detachedDiscarding { try await handler(reader, participantIdentity) }
            return
        }
        // Ordered topic. Wait only on handlers whose streams have already closed: this stream opened
        // after they ended, so it comes after them on the wire. Streams still open right now overlap
        // with this one and must not gate it.
        let streamID = info.id
        ordered.mutate { state in
            let token = state.makeToken()
            let predecessors = Array(state.finishing[topic]?.values ?? [:].values)
            state.openStreams[streamID] = .init(topic: topic, token: token)
            state.running[topic, default: [:]][token] = Task.detached { [weak self] in
                for predecessor in predecessors {
                    await predecessor.value
                }
                do {
                    try await handler(reader, participantIdentity)
                } catch {
                    self?.log("Ordered text stream handler for topic '\(topic)' threw: \(error)", .warning)
                }
                self?.handlerCompleted(topic: topic, streamID: streamID, token: token)
            }
        }
    }

    /// The stream closed on the wire. Its handler may still be running, and until it returns it gates
    /// streams that open from now on — so move it out of `runningHandlers` and into the set later
    /// streams wait for.
    func handleStreamClosed(streamID: String, identity _: String) {
        ordered.mutate { state in
            // Dropped here rather than on completion: the id is free again the moment the stream
            // ends, and a sender that reuses it must register a fresh entry.
            guard let entry = state.openStreams.removeValue(forKey: streamID) else { return }
            guard let task = state.running[entry.topic]?.removeValue(forKey: entry.token) else { return }
            state.finishing[entry.topic, default: [:]][entry.token] = task
        }
    }

    /// Handler returned: it no longer gates anything, so drop it and stop tracking its stream.
    private func handlerCompleted(topic: String, streamID: String, token: UInt64) {
        ordered.mutate { state in
            state.running[topic]?.removeValue(forKey: token)
            state.finishing[topic]?.removeValue(forKey: token)
            // Only if this handler is still the one that id maps to: a successor that reused the
            // id owns the entry now.
            if state.openStreams[streamID]?.token == token { state.openStreams[streamID] = nil }
        }
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
