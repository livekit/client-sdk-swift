/*
 * Copyright 2025 LiveKit
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

/// Manages state of incoming data streams.
actor IncomingStreamManager: Loggable {
    /// Information about an open data stream.
    private struct Descriptor {
        let info: StreamInfo
        let openTime: TimeInterval
        let continuation: StreamReaderSource.Continuation
        var readLength = 0
    }

    /// Mapping between stream ID and descriptor for open streams.
    private var openStreams: [String: Descriptor] = [:]
    /// Stream topics without a registered handler.
    private var failedToOpenStreams: Set<String> = []

    private var byteStreamHandlers: [String: ByteStreamHandler] = [:]
    private var textStreamHandlers: [String: TextStreamHandler] = [:]

    // MARK: - Handler registration

    func registerByteStreamHandler(for topic: String, _ onNewStream: @escaping ByteStreamHandler) throws {
        guard byteStreamHandlers[topic] == nil else {
            throw StreamError.handlerAlreadyRegistered
        }
        byteStreamHandlers[topic] = onNewStream
    }

    func registerTextStreamHandler(for topic: String, _ onNewStream: @escaping TextStreamHandler) throws {
        guard textStreamHandlers[topic] == nil else {
            throw StreamError.handlerAlreadyRegistered
        }
        textStreamHandlers[topic] = onNewStream
    }

    func unregisterByteStreamHandler(for topic: String) {
        byteStreamHandlers[topic] = nil
    }

    func unregisterTextStreamHandler(for topic: String) {
        textStreamHandlers[topic] = nil
    }

    // MARK: - Packet processing

    /// Handles a data stream header.
    func handle(header: Livekit_DataStream.Header, from identityString: String) {
        let identity = Participant.Identity(from: identityString)

        guard let streamInfo = Self.streamInfo(from: header) else {
            return
        }
        openStream(with: streamInfo, from: identity)
    }

    private func openStream(with info: StreamInfo, from identity: Participant.Identity) {
        guard openStreams[info.id] == nil else {
            return
        }
        guard let handler = handler(for: info) else {
            let topic = info.topic
            if !failedToOpenStreams.contains(topic) {
                logger.warning("Unable to find handler for incoming stream: \(info.id), topic: \(topic), opened by: \(identity)")
                failedToOpenStreams.insert(topic)
            }
            return
        }

        var continuation: StreamReaderSource.Continuation!
        let source = StreamReaderSource {
            $0.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                Task { await self.closeStream(with: info.id) }
            }
            continuation = $0
        }

        let descriptor = Descriptor(
            info: info,
            openTime: Date.timeIntervalSinceReferenceDate,
            continuation: continuation
        )
        openStreams[info.id] = descriptor

        Task.detached {
            try await handler(source, identity)
        }
    }

    /// Close the stream with the given id.
    private func closeStream(with id: String) {
        openStreams[id] = nil
    }

    /// Handles a data stream chunk.
    func handle(chunk: Livekit_DataStream.Chunk) {
        guard !chunk.content.isEmpty, let descriptor = openStreams[chunk.streamID] else { return }

        let readLength = descriptor.readLength + chunk.content.count

        if let totalLength = descriptor.info.totalLength {
            guard readLength <= totalLength else {
                descriptor.continuation.finish(throwing: StreamError.lengthExceeded)
                return
            }
        }
        openStreams[chunk.streamID]!.readLength = readLength
        descriptor.continuation.yield(chunk.content)
    }

    /// Handles a data stream trailer.
    func handle(trailer: Livekit_DataStream.Trailer) {
        guard let descriptor = openStreams[trailer.streamID] else {
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
    static func streamInfo(from header: Livekit_DataStream.Header) -> StreamInfo? {
        switch header.contentHeader {
        case let .byteHeader(byteHeader): ByteStreamInfo(header, byteHeader)
        case let .textHeader(textHeader): TextStreamInfo(header, textHeader)
        default: nil
        }
    }
}

extension ByteStreamInfo {
    convenience init(
        _ header: Livekit_DataStream.Header,
        _ byteHeader: Livekit_DataStream.ByteHeader
    ) {
        self.init(
            id: header.streamID,
            topic: header.topic,
            timestamp: header.timestampDate,
            totalLength: header.hasTotalLength ? Int(header.totalLength) : nil,
            attributes: header.attributes,
            // ---
            mimeType: header.mimeType,
            name: byteHeader.name
        )
    }
}

extension TextStreamInfo {
    convenience init(
        _ header: Livekit_DataStream.Header,
        _ textHeader: Livekit_DataStream.TextHeader
    ) {
        self.init(
            id: header.streamID,
            topic: header.topic,
            timestamp: header.timestampDate,
            totalLength: header.hasTotalLength ? Int(header.totalLength) : nil,
            attributes: header.attributes,
            // ---
            operationType: TextStreamInfo.OperationType(textHeader.operationType),
            version: Int(textHeader.version),
            replyToStreamID: !textHeader.replyToStreamID.isEmpty ? textHeader.replyToStreamID : nil,
            attachedStreamIDs: textHeader.attachedStreamIds,
            generated: textHeader.generated
        )
    }
}

extension TextStreamInfo.OperationType {
    init(_ operationType: Livekit_DataStream.OperationType) {
        self = Self(rawValue: operationType.rawValue) ?? .create
    }
}
