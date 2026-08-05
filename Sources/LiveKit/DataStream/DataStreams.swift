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

    // Created lazily on the first inbound packet, not at init: the incoming manager's payload cap
    // comes from the room's options, which aren't finalized until `connect` — after this coordinator
    // is built at `Room.init`. Deferring lets it pick up a `maxPayloadSize` passed at connect time.
    // StateSync-guarded so it's constructed exactly once even if packets race in.
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
    // Topics whose text handlers run in wire order. Successive streams from the *same sender* on
    // such a topic have their handlers serialized so they process in arrival order. Used by internal
    // consumers like transcription; off by default so concurrent consumers (e.g. RPC) aren't slowed.
    //
    // Keyed by sender identity within a topic — not by topic alone — so a still-open stream from one
    // sender doesn't block a concurrent stream from another (e.g. an agent transcript arriving while
    // a user transcript on the same topic is still streaming). A single sender's streams are
    // sequential in practice, so per-sender serialization preserves ordering without stalling peers.
    private let orderedTopics = StateSync<Set<String>>([])
    private let orderedTails = StateSync<[String: [String: Task<Void, Never>]]>([:])

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
        _incoming.mutate { existing in
            if let existing { return existing }
            let delegate = IncomingDelegate()
            delegate.coordinator = self
            // `nil` → the core's default cap. Read now (first packet, i.e. post-connect) so a
            // `maxPayloadSize` supplied via `connect(roomOptions:)` is honored.
            let maxPayloadSize = room?._state.roomOptions.dataStreamOptions.maxPayloadSize
            let manager = LiveKitUniFFI.IncomingDataStreamManager(
                delegate: delegate,
                maxPayloadByteLength: maxPayloadSize.map { UInt64($0) },
            )
            existing = manager
            return manager
        }
    }

    // Room-level encryption type, stamped onto every stream info as it crosses the FFI boundary.
    // The FFI hardcodes the info's encryption type to `.none` (E2EE-over-FFI is a follow-up); the
    // actual payload crypto still happens transparently in `DataChannelPair`, so we surface the
    // room's data-channel encryption type here to preserve the previous behavior.
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
        orderedTails.mutate { $0[topic] = nil }
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
    func handleIncoming(_ dataPacket: Livekit_DataPacket) {
        guard let data = try? dataPacket.serializedData() else { return }
        incomingManager().handlePacketReceived(packet: data)
    }

    // MARK: - Stream lifecycle

    /// Fails all open incoming streams so their handlers return (e.g. on cleanup). A handler blocked
    /// on a reader that will never finish would otherwise stall its topic's ordered queue. Handler
    /// registrations survive, so streams arriving after a reconnect are still handled.
    func reset() {
        // No-op if the incoming manager was never created (no packets received): nothing is open.
        _incoming.copy()?.abortAllStreams()
    }

    /// Fails open incoming streams sent by `identity` (they disconnected mid-send), so their readers
    /// throw and their handlers return instead of hanging.
    func closeStreams(from identity: Participant.Identity) {
        _incoming.copy()?.abortStreamsFrom(identity: identity.stringValue)
    }

    // MARK: - Stream open dispatch (called from the incoming delegate)

    fileprivate func handleByteStreamOpened(_ ffiReader: LiveKitUniFFI.ByteStreamReader, identity: String) {
        let info = ByteStreamInfo(ffiReader.info(), encryptionType: currentEncryptionType)
        guard let handler = byteStreamHandlers.copy()[info.topic] else {
            logMissingHandler(topic: info.topic, id: info.id, identity: identity)
            return
        }
        let reader = ByteStreamReader(ffiReader, info: info)
        let participantIdentity = Participant.Identity(from: identity)
        Task.detachedDiscarding { try await handler(reader, participantIdentity) }
    }

    fileprivate func handleTextStreamOpened(_ ffiReader: LiveKitUniFFI.TextStreamReader, identity: String) {
        let info = TextStreamInfo(ffiReader.info(), encryptionType: currentEncryptionType)
        guard let handler = textStreamHandlers.copy()[info.topic] else {
            logMissingHandler(topic: info.topic, id: info.id, identity: identity)
            return
        }
        let reader = TextStreamReader(ffiReader, info: info)
        let participantIdentity = Participant.Identity(from: identity)
        guard orderedTopics.copy().contains(info.topic) else {
            Task.detachedDiscarding { try await handler(reader, participantIdentity) }
            return
        }
        // Ordered topic: chain this handler after the previous one from the *same sender* so that
        // sender's successive streams process in arrival order — while streams from other senders on
        // the topic run concurrently (a still-open stream from one sender never blocks another's).
        let topic = info.topic
        orderedTails.mutate { tails in
            let predecessor = tails[topic]?[identity]
            tails[topic, default: [:]][identity] = Task.detached { [weak self] in
                await predecessor?.value
                do {
                    try await handler(reader, participantIdentity)
                } catch {
                    self?.log("Ordered text stream handler for topic '\(topic)' threw: \(error)", .warning)
                }
            }
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

    // MARK: - Incoming delegate

    /// Receives the incoming manager's stream-open callbacks and forwards them to the coordinator.
    /// A separate object because the FFI manager retains its delegate strongly; holding the
    /// coordinator weakly keeps this the weak link so teardown doesn't leak.
    private final class IncomingDelegate: LiveKitUniFFI.IncomingDataStreamManagerDelegate, @unchecked Sendable {
        weak var coordinator: DataStreams?

        func onByteStreamOpened(reader: LiveKitUniFFI.ByteStreamReader, identity: String) {
            coordinator?.handleByteStreamOpened(reader, identity: identity)
        }

        func onTextStreamOpened(reader: LiveKitUniFFI.TextStreamReader, identity: String) {
            coordinator?.handleTextStreamOpened(reader, identity: identity)
        }
    }

    // MARK: - Outgoing delegate

    /// Receives the outgoing manager's encoded `DataPacket`s and sends them over the reliable data
    /// channel via `Room.send(dataPacket:)` — preserving E2EE, reliable sequencing, and identity
    /// stamping. Serialized so packets reach the SFU in the order the manager emits them; the room
    /// is held weakly to avoid retaining it through the FFI manager.
    private final class OutgoingDelegate: LiveKitUniFFI.OutgoingDataStreamManagerDelegate, @unchecked Sendable {
        private let sender = AsyncSerialDelegate<Room>()

        init(room: Room) {
            sender.set(delegate: room)
        }

        func onPacketsAvailable(packets: [Data]) {
            sender.notifyDetached { room in
                for data in packets {
                    guard let packet = try? Livekit_DataPacket(serializedBytes: data) else {
                        room.log("Failed to decode outgoing data stream packet", .warning)
                        continue
                    }
                    try? await room.send(dataPacket: packet)
                }
            }
        }
    }

    // MARK: - Remote participant registry

    /// Read access to the room's remote participants, used by the outgoing manager to resolve
    /// broadcast recipients and decide compression eligibility. Client protocol/capabilities aren't
    /// currently exposed on `RemoteParticipant`, so they default to none — compression stays off
    /// until they're wired, which is a safe default (a non-compressed send always works).
    private final class Registry: LiveKitUniFFI.RemoteParticipantRegistryDelegate, @unchecked Sendable {
        private weak var room: Room?

        init(room: Room) {
            self.room = room
        }

        private func participant(for identity: String) -> RemoteParticipant? {
            room?.remoteParticipants.first { $0.key.stringValue == identity }?.value
        }

        func remoteClientProtocol(identity: String) -> Int32 {
            Int32(participant(for: identity)?.clientProtocol.rawValue ?? 0)
        }

        func remoteCapabilities(identity: String) -> [LiveKitUniFFI.ClientCapability] {
            participant(for: identity)?.capabilities.map(\.ffiValue) ?? []
        }

        func remoteIdentities() -> [String] {
            guard let room else { return [] }
            return room.remoteParticipants.keys.map(\.stringValue)
        }
    }
}

private extension ClientCapability {
    /// Bridges to the FFI enum. Kept here so `ClientCapability` itself stays free of any
    /// `LiveKitUniFFI` import, matching how the rest of the public API is layered.
    var ffiValue: LiveKitUniFFI.ClientCapability {
        switch self {
        case .packetTrailer: .packetTrailer
        case .compressionDeflateRaw: .compressionDeflateRaw
        }
    }
}
