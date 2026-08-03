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

// swiftlint:disable file_length

/// Manages state of incoming data streams.
actor IncomingStreamManager: Loggable {
    /// Information about an open data stream.
    private struct Descriptor {
        /// Distinguishes this descriptor from others that reuse the same stream
        /// ID, so a stale cleanup can't remove a successor.
        let generation = UUID()
        let info: StreamInfo
        let identity: Participant.Identity
        let continuation: StreamReaderSource.Continuation
        var readLength = 0
    }

    /// Mapping between stream ID and descriptor for open streams.
    private var openStreams: [String: Descriptor] = [:]

    var openStreamCount: Int { openStreams.count }
    /// Stream topics without a registered handler.
    private var failedToOpenStreams: Set<String> = []

    private var byteStreamHandlers: [String: ByteStreamHandler] = [:]
    private var textStreamHandlers: [String: TextStreamHandler] = [:]

    /// Topics whose handlers preserve wire order (see `registerTextStreamHandler`).
    private var orderedTopics: Set<String> = []
    /// Handlers of streams that are still open on the wire, keyed by topic and
    /// descriptor generation. Open streams gate nothing.
    private var runningHandlers: [String: [UUID: Task<Void, Never>]] = [:]
    /// Handlers of streams already closed on the wire but still executing (e.g.
    /// draining buffered chunks or emitting a finalization). A new stream on the
    /// topic opened after these closed, so its handler must wait for them.
    private var finishingHandlers: [String: [UUID: Task<Void, Never>]] = [:]

    /// Events are processed in a serial (FIFO) order
    enum StreamEvent {
        case header(Livekit_DataStream.Header, String, EncryptionType)
        case chunk(Livekit_DataStream.Chunk, EncryptionType)
        case trailer(Livekit_DataStream.Trailer, EncryptionType)
    }

    private let eventContinuation: AsyncStream<StreamEvent>.Continuation
    private var eventLoopTask: AnyTaskCancellable?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        eventContinuation = continuation

        Task {
            await observe(events: stream)
        }
    }

    private func observe(events stream: AsyncStream<StreamEvent>) {
        eventLoopTask = stream.subscribe(self) { observer, event in
            await observer.process(event)
        }
    }

    nonisolated func handle(_ event: StreamEvent) {
        eventContinuation.yield(event)
    }

    private func process(_ event: StreamEvent) {
        switch event {
        case let .header(header, identityString, encryptionType):
            handle(header: header, from: identityString, encryptionType: encryptionType)
        case let .chunk(chunk, encryptionType):
            handle(chunk: chunk, encryptionType: encryptionType)
        case let .trailer(trailer, encryptionType):
            handle(trailer: trailer, encryptionType: encryptionType)
        }
    }

    // MARK: - Handler registration

    func registerByteStreamHandler(for topic: String, _ onNewStream: @escaping ByteStreamHandler) throws {
        guard byteStreamHandlers[topic] == nil else {
            throw StreamError.handlerAlreadyRegistered
        }
        byteStreamHandlers[topic] = onNewStream
    }

    /// When `ordered` is true, handlers for streams that do not overlap on the
    /// wire run in wire order: a stream opened after another closed waits for the
    /// earlier handler to finish. Streams that are open concurrently are handled
    /// concurrently, so a still-open stream never delays later ones. Off by
    /// default: it would serialize consumers that want strict concurrency (e.g.
    /// RPC request handling).
    ///
    /// Contract: an ordered handler should return promptly once its reader ends —
    /// work it keeps doing after its stream closed delays every later
    /// non-overlapping stream on the topic.
    func registerTextStreamHandler(for topic: String, ordered: Bool = false, _ onNewStream: @escaping TextStreamHandler) throws {
        guard textStreamHandlers[topic] == nil else {
            throw StreamError.handlerAlreadyRegistered
        }
        textStreamHandlers[topic] = onNewStream
        if ordered { orderedTopics.insert(topic) }
    }

    /// SDK-internal: register `onNewStream` for `topic` if no handler is registered yet,
    /// otherwise no-op. Used by idempotent wiring paths (e.g. RPC v2 setup runs on every
    /// connect) that don't want the duplicate-registration throw from the public API.
    @discardableResult
    func registerTextStreamHandlerIfNeeded(for topic: String, _ onNewStream: @escaping TextStreamHandler) -> Bool {
        guard textStreamHandlers[topic] == nil else { return false }
        textStreamHandlers[topic] = onNewStream
        return true
    }

    func unregisterByteStreamHandler(for topic: String) {
        byteStreamHandlers[topic] = nil
    }

    func unregisterTextStreamHandler(for topic: String) {
        textStreamHandlers[topic] = nil
        orderedTopics.remove(topic)
    }

    // MARK: - Packet processing

    /// Handles a data stream header.
    private func handle(header: Livekit_DataStream.Header, from identityString: String, encryptionType: EncryptionType) {
        let identity = Participant.Identity(from: identityString)

        guard let streamInfo = Self.streamInfo(from: header, encryptionType: encryptionType) else {
            return
        }
        openStream(with: streamInfo, from: identity)
    }

    private func openStream(with info: StreamInfo, from identity: Participant.Identity) {
        guard openStreams[info.id] == nil else {
            log("Ignoring stream \(info.id) from \(identity): a stream with this ID is already open", .warning)
            return
        }
        guard let handler = handler(for: info) else {
            let topic = info.topic
            if !failedToOpenStreams.contains(topic) {
                log("Unable to find handler for incoming stream: \(info.id), topic: \(topic), opened by: \(identity)", .warning)
                failedToOpenStreams.insert(topic)
            }
            return
        }

        var continuation: StreamReaderSource.Continuation!
        let source = StreamReaderSource {
            continuation = $0
        }

        let descriptor = Descriptor(
            info: info,
            identity: identity,
            continuation: continuation,
        )
        openStreams[info.id] = descriptor

        // Set after the descriptor is stored: this task runs at an arbitrary
        // later point, and a sender may have reused the stream ID by then, so
        // it must only remove its own generation.
        continuation.onTermination = { @Sendable [weak self, generation = descriptor.generation] _ in
            guard let self else { return }
            Task { await self.closeStream(with: info.id, generation: generation) }
        }

        // Detached: handler lifetime is not tied to the descriptor — abnormal stream
        // conditions are signalled through `source` throwing instead.
        if orderedTopics.contains(info.topic) {
            // Wire happens-before: this stream opened after `predecessors` closed,
            // so their handlers must finish first. Same-segment streams never
            // overlap (senders close one before opening the next), which is what
            // makes finalizations and stream-ID reuse race-free.
            let predecessors = Array((finishingHandlers[info.topic] ?? [:]).values)
            let topic = info.topic
            let generation = descriptor.generation
            let task = Task.detached { [weak self] in
                for predecessor in predecessors {
                    await predecessor.value
                }
                do {
                    try await handler(source, identity)
                } catch {
                    self?.log("Text stream handler for topic '\(topic)' threw: \(error)", .warning)
                }
                await self?.handlerCompleted(topic: topic, generation: generation)
            }
            runningHandlers[topic, default: [:]][generation] = task
        } else {
            Task.detachedDiscarding {
                try await handler(source, identity)
            }
        }
    }

    /// Marks the stream's handler as gating later non-overlapping streams on the
    /// same ordered topic. Called wherever a stream is closed on the wire.
    private func streamDidClose(_ descriptor: Descriptor) {
        let topic = descriptor.info.topic
        if let task = runningHandlers[topic]?.removeValue(forKey: descriptor.generation) {
            finishingHandlers[topic, default: [:]][descriptor.generation] = task
        }
    }

    private func handlerCompleted(topic: String, generation: UUID) {
        runningHandlers[topic]?[generation] = nil
        finishingHandlers[topic]?[generation] = nil
    }

    /// Close the stream with the given id, unless it has been superseded by a
    /// newer stream reusing the same id.
    private func closeStream(with id: String, generation: UUID) {
        guard openStreams[id]?.generation == generation else { return }
        openStreams[id] = nil
    }

    /// Fails all open streams from the given participant, whose trailers can no
    /// longer arrive; their readers throw and their handlers return.
    func closeStreams(from identity: Participant.Identity) {
        for (id, descriptor) in openStreams where descriptor.identity == identity {
            openStreams[id] = nil
            streamDidClose(descriptor)
            descriptor.continuation.finish(throwing: StreamError.terminated)
        }
    }

    /// Fails all open streams. Handler registrations survive so streams arriving
    /// after a reconnect are still handled.
    func reset() {
        for descriptor in openStreams.values {
            streamDidClose(descriptor)
            descriptor.continuation.finish(throwing: StreamError.terminated)
        }
        openStreams.removeAll()
    }

    /// Handles a data stream chunk.
    private func handle(chunk: Livekit_DataStream.Chunk, encryptionType: EncryptionType) {
        guard !chunk.content.isEmpty, let descriptor = openStreams[chunk.streamID] else { return }

        // Error paths remove the descriptor synchronously for the same reason as
        // the trailer path: a header reusing this stream ID may be the next event.
        if descriptor.info.encryptionType != encryptionType {
            let error = StreamError.encryptionTypeMismatch(
                expected: descriptor.info.encryptionType,
                received: encryptionType,
            )
            openStreams[chunk.streamID] = nil
            streamDidClose(descriptor)
            descriptor.continuation.finish(throwing: error)
            return
        }

        let readLength = descriptor.readLength + chunk.content.count

        if let totalLength = descriptor.info.totalLength {
            guard readLength <= totalLength else {
                openStreams[chunk.streamID] = nil
                streamDidClose(descriptor)
                descriptor.continuation.finish(throwing: StreamError.lengthExceeded)
                return
            }
        }
        openStreams[chunk.streamID]!.readLength = readLength
        descriptor.continuation.yield(chunk.content)
    }

    /// Handles a data stream trailer.
    private func handle(trailer: Livekit_DataStream.Trailer, encryptionType: EncryptionType) {
        guard let descriptor = openStreams[trailer.streamID] else {
            return
        }

        // Remove synchronously: senders may reuse a stream ID, and the reopening
        // header is processed by this same event loop right after the trailer.
        // The reader's `onTermination` cleanup runs in its own task and can lose
        // that race, making `openStream` silently drop the new stream.
        openStreams[trailer.streamID] = nil
        streamDidClose(descriptor)

        if descriptor.info.encryptionType != encryptionType {
            let error = StreamError.encryptionTypeMismatch(
                expected: descriptor.info.encryptionType,
                received: encryptionType,
            )
            descriptor.continuation.finish(throwing: error)
            return
        }

        if let totalLength = descriptor.info.totalLength {
            guard descriptor.readLength == totalLength else {
                descriptor.continuation.finish(throwing: StreamError.incomplete)
                return
            }
        }
        guard trailer.reason.isEmpty else {
            // According to protocol documentation, a non-empty reason string indicates an error
            let error = StreamError.abnormalEnd(reason: trailer.reason)
            descriptor.continuation.finish(throwing: error)
            return
        }
        descriptor.continuation.finish()
    }

    // MARK: - Handler resolution

    /// Type-erased stream handler.
    private typealias AnyStreamHandler = @Sendable (StreamReaderSource, Participant.Identity) async throws -> Void

    /// Finds a registered handler suitable for handling the stream with the given info.
    private func handler(for info: StreamInfo) -> AnyStreamHandler? {
        if let info = info as? ByteStreamInfo,
           let registerdHandler = byteStreamHandlers[info.topic]
        {
            return { try await registerdHandler(ByteStreamReader(info: info, source: $0), $1) }
        }
        if let info = info as? TextStreamInfo,
           let registerdHandler = textStreamHandlers[info.topic]
        {
            return { try await registerdHandler(TextStreamReader(info: info, source: $0), $1) }
        }
        return nil
    }

    // MARK: - Clean up

    deinit {
        eventContinuation.finish()
        guard !openStreams.isEmpty else { return }
        for descriptor in openStreams.values {
            descriptor.continuation.finish(throwing: StreamError.terminated)
        }
    }
}

// MARK: - Type aliases

/// Handler for incoming byte data streams.
public typealias ByteStreamHandler = @Sendable (ByteStreamReader, Participant.Identity) async throws -> Void

/// Handler for incoming text data streams.
public typealias TextStreamHandler = @Sendable (TextStreamReader, Participant.Identity) async throws -> Void

// MARK: - From protocol types

extension IncomingStreamManager {
    static func streamInfo(from header: Livekit_DataStream.Header, encryptionType: EncryptionType) -> StreamInfo? {
        switch header.contentHeader {
        case let .byteHeader(byteHeader): ByteStreamInfo(header, byteHeader, encryptionType)
        case let .textHeader(textHeader): TextStreamInfo(header, textHeader, encryptionType)
        default: nil
        }
    }
}

extension ByteStreamInfo {
    convenience init(
        _ header: Livekit_DataStream.Header,
        _ byteHeader: Livekit_DataStream.ByteHeader,
        _ encryptionType: EncryptionType,
    ) {
        self.init(
            id: header.streamID,
            topic: header.topic,
            timestamp: header.timestampDate,
            totalLength: header.hasTotalLength ? Int(header.totalLength) : nil,
            attributes: header.attributes,
            encryptionType: encryptionType,
            // ---
            mimeType: header.mimeType,
            name: byteHeader.name,
        )
    }
}

extension TextStreamInfo {
    convenience init(
        _ header: Livekit_DataStream.Header,
        _ textHeader: Livekit_DataStream.TextHeader,
        _ encryptionType: EncryptionType,
    ) {
        self.init(
            id: header.streamID,
            topic: header.topic,
            timestamp: header.timestampDate,
            totalLength: header.hasTotalLength ? Int(header.totalLength) : nil,
            attributes: header.attributes,
            encryptionType: encryptionType,
            // ---
            operationType: TextStreamInfo.OperationType(textHeader.operationType),
            version: Int(textHeader.version),
            replyToStreamID: !textHeader.replyToStreamID.isEmpty ? textHeader.replyToStreamID : nil,
            attachedStreamIDs: textHeader.attachedStreamIds,
            generated: textHeader.generated,
        )
    }
}

extension TextStreamInfo.OperationType {
    init(_ operationType: Livekit_DataStream.OperationType) {
        self = Self(rawValue: operationType.rawValue) ?? .create
    }
}

// swiftlint:enable file_length
