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

// MARK: - DataStreams

/// Room-scoped topic handlers; native sessions own stream transport and lifetime.
/// The weak room reference is assigned only during Room.init, before it can escape.
final class DataStreams: NSObject, @unchecked Sendable, Loggable {
    private func outgoing() throws -> LiveKitFFI.FfiRoom {
        guard let room else { throw LiveKitError(.invalidState, message: "Room is gone") }
        return try room.requireNativeRoom(forEncryptedPayload: true)
    }

    // Held weakly: the Room owns this coordinator, so the back-reference must not retain it. Used
    // for the room-level encryption type stamped onto stream info, and for logging.
    private weak var room: Room?

    // The Swift-side handler registry. The FFI reports every opened stream regardless of topic
    // (`onByteStreamOpened`/`onTextStreamOpened`); we route by `info.topic` to these handlers.
    private let byteStreamHandlers = StateSync<[String: ByteStreamHandler]>([:])
    private let textStreamHandlers = StateSync<[String: TextStreamHandler]>([:])

    /// Supplies the back-reference, in `Room.init`'s second phase.
    ///
    /// Split from `init` because this subsystem is staged inside `Room.State` — built in the first
    /// phase, where `self` isn't available yet. Nothing can reach the room, and so nothing can reach
    /// this reference, until its initializer returns.
    func attach(room: Room) {
        self.room = room
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
        guard !ordered else {
            throw LiveKitError(.invalidState, message: "Ordered text handlers need a native stream-close event")
        }
        try textStreamHandlers.mutate {
            guard $0[topic] == nil else { throw StreamError.handlerAlreadyRegistered }
            $0[topic] = onNewStream
        }
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
    }

    // MARK: - Sending

    func sendText(_ text: String, options: StreamTextOptions, onProgress: (@Sendable (StreamProgress) -> Void)? = nil) async throws -> TextStreamInfo {
        var options = options.ffi
        options.progress = onProgress.map(ProgressDelegate.init)
        return try await TextStreamInfo(calling { [options] in try await $0.sendText(text: text, options: options) }, encryptionType: currentEncryptionType)
    }

    /// Sends `text`, then each file in `attachments` as its own byte stream, the files at the same
    /// time, as JS does. The text lists the files' stream IDs in its attached stream IDs; each file
    /// goes on the text's topic, to its recipients, with its compression and sender. The first file
    /// that fails ends the call and cancels the others.
    func sendText(_ text: String, options: StreamTextOptions, attachments: [URL]) async throws -> TextStreamInfo {
        let ids = attachments.map { _ in UUID().uuidString }
        let info = try await sendText(text, options: options.attaching(ids))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (fileURL, id) in zip(attachments, ids) {
                let fileOptions = StreamByteOptions(
                    topic: options.topic,
                    destinationIdentities: options.destinationIdentities,
                    id: id,
                    compress: options.compress,
                    senderIdentity: options.senderIdentity,
                )
                group.addTask { _ = try await self.sendFile(fileURL, options: fileOptions) }
            }
            // Not `waitForAll()`, which waits for every file even after one has failed: the first
            // error leaves the group, which cancels the other sends.
            for try await _ in group {}
        }
        return info
    }

    func sendBytes(_ data: Data, options: StreamByteOptions, onProgress: (@Sendable (StreamProgress) -> Void)? = nil) async throws -> ByteStreamInfo {
        var options = options.ffi
        options.progress = onProgress.map(ProgressDelegate.init)
        return try await ByteStreamInfo(calling { [options] in try await $0.sendBytes(data: data, options: options) }, encryptionType: currentEncryptionType)
    }

    func sendFile(_ fileURL: URL, options: StreamByteOptions, onProgress: (@Sendable (StreamProgress) -> Void)? = nil) async throws -> ByteStreamInfo {
        // Supply the name/MIME defaults from disk unless the caller set them. The core derives
        // the file's size itself.
        guard let fileInfo = FileInfo(for: fileURL) else {
            throw StreamError.fileInfoUnavailable
        }
        var ffiOptions = options.ffi
        ffiOptions.mimeType = options.mimeType ?? fileInfo.mimeType
        ffiOptions.name = options.name ?? fileInfo.name
        ffiOptions.progress = onProgress.map(ProgressDelegate.init)
        return try await ByteStreamInfo(calling { [ffiOptions] in try await $0.sendFile(path: fileURL.path, options: ffiOptions) }, encryptionType: currentEncryptionType)
    }

    func streamText(options: StreamTextOptions) async throws -> TextStreamWriter {
        let options = options.ffi
        return try await TextStreamWriter(calling { try await $0.streamText(options: options) }, encryptionType: currentEncryptionType)
    }

    func streamBytes(options: StreamByteOptions) async throws -> ByteStreamWriter {
        let options = options.ffi
        return try await ByteStreamWriter(calling { try await $0.streamBytes(options: options) }, encryptionType: currentEncryptionType)
    }

    // MARK: - Native stream open events

    func handleByteStreamOpened(_ ffiReader: LiveKitFFI.ByteStreamReader, identity: String) {
        let reader = ByteStreamReader(ffiReader)
        let info = reader.info
        guard let handler = byteStreamHandlers.copy()[info.topic] else {
            logMissingHandler(topic: info.topic, id: info.id, identity: identity)
            return
        }
        let participantIdentity = Participant.Identity(from: identity)
        Task.detachedDiscarding { try await handler(reader, participantIdentity) }
    }

    func handleTextStreamOpened(_ ffiReader: LiveKitFFI.TextStreamReader, identity: String) {
        let reader = TextStreamReader(ffiReader)
        let info = reader.info
        guard let entry = textStreamHandlers.copy()[info.topic] else {
            logMissingHandler(topic: info.topic, id: info.id, identity: identity)
            return
        }
        let participantIdentity = Participant.Identity(from: identity)
        Task.detachedDiscarding { try await entry(reader, participantIdentity) }
    }

    private func logMissingHandler(topic: String, id: String, identity: String) {
        log("Unable to find handler for incoming stream: \(id), topic: \(topic), opened by: \(identity)")
    }

    /// Runs `call` on the active native session. A cancel ends the wait at once, since the
    /// UniFFI call ignores it, and an FFI error becomes a ``StreamError``.
    private func calling<T: Sendable>(_ call: @escaping @Sendable (LiveKitFFI.FfiRoom) async throws -> T) async throws -> T {
        let outgoing = try outgoing()
        do {
            return try await abandoningOnCancel { try await call(outgoing) }
        } catch let error as LiveKitFFI.DataStreamError {
            throw StreamError.fromNative(error)
        }
    }
}
