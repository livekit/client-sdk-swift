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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Exercises the incoming data-stream path end-to-end through the ``DataStreams`` coordinator (which
/// is backed by the UniFFI Rust core), validating that the pre-existing v1 behaviors — handler
/// registration, chunk assembly, and error surfacing — still hold. Packets are fed straight into the
/// coordinator via ``DataStreams/handleIncoming(_:)``, so no network or connected room is needed.
@Suite(.tags(.dataStream))
struct IncomingStreamManagerTests: Sendable {
    let room: Room
    let coordinator: DataStreams

    let topicName = "someTopic"
    let participant = Participant.Identity(from: "someName")

    init() throws {
        room = Room()
        coordinator = room.dataStreams
        // The incoming manager is connection-scoped, so packets fed at `.idle` would be dropped.
        let connection = ConnectionDependencies(idle: room._state.stage.idle, room: room, roomOptions: RoomOptions())
        try room._state.mutate { try $0.stage.begin(connection) }
    }

    @Test func registerByteHandler() throws {
        try coordinator.registerByteStreamHandler(for: topicName) { _, _ in }

        #expect(throws: StreamError.handlerAlreadyRegistered) {
            try coordinator.registerByteStreamHandler(for: topicName) { _, _ in }
        }

        coordinator.unregisterByteStreamHandler(for: topicName)
        // Re-registration succeeds once unregistered.
        try coordinator.registerByteStreamHandler(for: topicName) { _, _ in }
    }

    @Test func registerTextHandler() throws {
        try coordinator.registerTextStreamHandler(for: topicName) { _, _ in }

        #expect(throws: StreamError.handlerAlreadyRegistered) {
            try coordinator.registerTextStreamHandler(for: topicName) { _, _ in }
        }

        coordinator.unregisterTextStreamHandler(for: topicName)
        try coordinator.registerTextStreamHandler(for: topicName) { _, _ in }
    }

    @Test func byteStream() async throws {
        let testChunks = [
            Data(repeating: 0xAB, count: 128),
            Data(repeating: 0xCD, count: 128),
            Data(repeating: 0xEF, count: 256),
            Data(repeating: 0x12, count: 32),
        ]
        let testPayload = testChunks.reduce(Data()) { $0 + $1 }

        let read = try readingByteStreams()
        await feedByteStream(chunks: testChunks)

        #expect(try await read.wait() == testPayload)
    }

    @Test func textStream() async throws {
        let testChunks = [
            String(repeating: "A", count: 128),
            String(repeating: "B", count: 128),
            String(repeating: "C", count: 256),
            String(repeating: "D", count: 32),
        ]
        let testPayload = testChunks.reduce("") { $0 + $1 }

        let read = try readingTextStreams()
        await feedTextStream(chunks: testChunks)

        #expect(try await read.wait() == testPayload)
    }

    @Test func nonTextData() async throws {
        // A text stream carrying non-UTF-8 bytes surfaces `.invalidUTF8` with the decoder's detail.
        let rawPayload = Data(repeating: 0xAB, count: 128)

        let read = try readingTextStreams()
        await feedTextStream(rawPayload: rawPayload)

        let error = try #require(await #expect(throws: StreamError.self) { try await read.wait() })
        guard case let .invalidUTF8(reason) = error else {
            Issue.record("Expected .invalidUTF8, got \(error)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func abnormalClosure() async throws {
        let closureReason = "test"

        let error = try await byteReaderError { streamID in
            feedHeader(streamID: streamID, byte: true)
            feedTrailer(streamID: streamID, reason: closureReason)
        }

        #expect(error as? StreamError == .abnormalEnd(reason: closureReason))
    }

    @Test func incomplete() async throws {
        let testPayload = Data(repeating: 0xAB, count: 128)

        let error = try await byteReaderError { streamID in
            feedHeader(streamID: streamID, byte: true, totalLength: UInt64(testPayload.count + 10))
            feedChunk(streamID: streamID, index: 0, content: testPayload)
            feedTrailer(streamID: streamID, reason: "")
        }

        #expect(error as? StreamError == .incomplete)
    }

    /// A stream is opened as encrypted; a peer then tries to continue it in the clear. Both the
    /// chunk and the trailer paths must reject that — the trailer especially, since merging its
    /// attributes is how an unencrypted peer could otherwise close someone else's encrypted stream
    /// and inject attributes on the way out.
    @Test(arguments: [false, true])
    func encryptionTypeMismatch(onTrailer: Bool) async throws {
        let error = try await byteReaderError { streamID in
            feedHeader(streamID: streamID, byte: true, encryptionType: .gcm)
            feedChunk(
                streamID: streamID,
                index: 0,
                content: Data(repeating: 0xAB, count: 16),
                encryptionType: onTrailer ? .gcm : .none,
            )
            feedTrailer(streamID: streamID, reason: "", encryptionType: onTrailer ? .none : .gcm)
        }

        #expect(error as? StreamError == .encryptionTypeMismatch(expected: .gcm, received: .none))
    }

    /// A stream failing mid-flight (here: exceeding its declared length) must not block a new
    /// stream that immediately reuses the same stream id. v1's spec, re-pointed at the core.
    @Test func reusedStreamIDAfterChunkErrorDeliversNextStream() async throws {
        let received = StateSync<[String]>([])

        try coordinator.registerTextStreamHandler(for: topicName) { reader, _ in
            let payload = try await reader.readAll()
            received.mutate { $0.append(payload) }
        }

        let streamID = UUID().uuidString
        // 8-byte chunk against a declared total of 4 → lengthExceeded.
        await feedTextStream(rawPayload: Data("ABCDEFGH".utf8), totalLength: 4, streamID: streamID)
        await feedTextStream(chunks: ["ok"], streamID: streamID)

        let deadline = Date().addingTimeInterval(10)
        while received.copy().isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(received.copy() == ["ok"])
        coordinator.unregisterTextStreamHandler(for: topicName)
    }

    /// A header's length is a remote `UInt64`, and the core opens the stream before it checks the
    /// length against the cap, so the handler sees it. A length `Int` can't hold reads as unknown.
    @Test(arguments: [false, true])
    func oversizedTotalLengthReadsAsUnknown(byte: Bool) async throws {
        let totalLength = AsyncCompleter<Int?>(label: "Stream opened", defaultTimeout: 10)
        if byte {
            try coordinator.registerByteStreamHandler(for: topicName) { reader, _ in
                totalLength.resume(returning: reader.info.totalLength)
            }
        } else {
            try coordinator.registerTextStreamHandler(for: topicName) { reader, _ in
                totalLength.resume(returning: reader.info.totalLength)
            }
        }
        feedHeader(streamID: UUID().uuidString, byte: byte, totalLength: .max)

        #expect(try await totalLength.wait() == nil)
    }

    /// The info is built before the handler lookup, so a stream on a topic nobody handles must not
    /// trap either. Stream-open callbacks run in order, so reaching the handled stream proves the
    /// unhandled ones returned.
    @Test func oversizedTotalLengthOnUnhandledTopic() async throws {
        let read = try readingTextStreams()
        feedHeader(streamID: UUID().uuidString, byte: false, totalLength: .max, topic: "unhandled")
        feedHeader(streamID: UUID().uuidString, byte: true, totalLength: .max, topic: "unhandled")
        await feedTextStream(chunks: ["ok"])

        #expect(try await read.wait() == "ok")
    }

    // MARK: - Helpers

    /// Registers a byte handler that reads each stream on `topicName` to the end. The completer
    /// fails after a timeout instead of hanging the suite on a stream that never arrives.
    private func readingByteStreams() throws -> AsyncCompleter<Data> {
        let read = AsyncCompleter<Data>(label: "Byte stream read", defaultTimeout: 10)
        try coordinator.registerByteStreamHandler(for: topicName) { reader, participant in
            #expect(participant == self.participant)
            do {
                try await read.resume(returning: reader.readAll())
            } catch {
                read.resume(throwing: error)
            }
        }
        return read
    }

    /// The text counterpart of ``readingByteStreams()``.
    private func readingTextStreams() throws -> AsyncCompleter<String> {
        let read = AsyncCompleter<String>(label: "Text stream read", defaultTimeout: 10)
        try coordinator.registerTextStreamHandler(for: topicName) { reader, participant in
            #expect(participant == self.participant)
            do {
                try await read.resume(returning: reader.readAll())
            } catch {
                read.resume(throwing: error)
            }
        }
        return read
    }

    /// Feeds a byte stream via `feed(streamID:)` and returns the error its read throws, or `nil`
    /// on success.
    private func byteReaderError(feeding feed: (String) -> Void) async throws -> Error? {
        let read = try readingByteStreams()
        feed(UUID().uuidString)
        do {
            _ = try await read.wait()
            return nil
        } catch {
            return error
        }
    }

    private func feedByteStream(chunks: [Data]) async {
        let streamID = UUID().uuidString
        feedHeader(streamID: streamID, byte: true)
        for (index, chunk) in chunks.enumerated() {
            feedChunk(streamID: streamID, index: UInt64(index), content: chunk)
        }
        feedTrailer(streamID: streamID, reason: "")
    }

    func feedTextStream(
        chunks: [String]? = nil,
        rawPayload: Data? = nil,
        totalLength: UInt64? = nil,
        streamID: String = UUID().uuidString,
    ) async {
        feedHeader(streamID: streamID, byte: false, totalLength: totalLength)
        if let chunks {
            for (index, chunk) in chunks.enumerated() {
                feedChunk(streamID: streamID, index: UInt64(index), content: Data(chunk.utf8))
            }
        } else if let rawPayload {
            feedChunk(streamID: streamID, index: 0, content: rawPayload)
        }
        feedTrailer(streamID: streamID, reason: "")
    }

    func feedTextHeader(streamID: String) {
        feedHeader(streamID: streamID, byte: false)
    }

    func feedTextChunk(streamID: String, content: String) {
        feedChunk(streamID: streamID, index: 0, content: Data(content.utf8))
    }

    func feedTextTrailer(streamID: String) {
        feedTrailer(streamID: streamID, reason: "")
    }

    func feedHeader(
        streamID: String,
        byte: Bool,
        totalLength: UInt64? = nil,
        encryptionType: EncryptionType = .none,
        topic: String? = nil,
    ) {
        let header = Livekit_DataStream.Header.with {
            $0.streamID = streamID
            $0.topic = topic ?? topicName
            $0.contentHeader = byte
                ? .byteHeader(Livekit_DataStream.ByteHeader())
                : .textHeader(Livekit_DataStream.TextHeader())
            if let totalLength { $0.totalLength = totalLength }
        }
        feed(encryptionType: encryptionType) { $0.streamHeader = header }
    }

    func feedChunk(streamID: String, index: UInt64, content: Data, encryptionType: EncryptionType = .none) {
        let chunk = Livekit_DataStream.Chunk.with {
            $0.streamID = streamID
            $0.chunkIndex = index
            $0.content = content
        }
        feed(encryptionType: encryptionType) { $0.streamChunk = chunk }
    }

    func feedTrailer(streamID: String, reason: String, encryptionType: EncryptionType = .none) {
        let trailer = Livekit_DataStream.Trailer.with {
            $0.streamID = streamID
            $0.reason = reason
        }
        feed(encryptionType: encryptionType) { $0.streamTrailer = trailer }
    }

    /// `serialized: nil` drives the re-encode fallback — the path a decrypted packet takes, since
    /// its received bytes no longer describe it. The reuse path is covered end-to-end by
    /// ``DataStreamTests``, which feeds real bytes off the wire.
    private func feed(encryptionType: EncryptionType = .none, _ configure: (inout Livekit_DataPacket.Builder) -> Void) {
        let packet = Livekit_DataPacket.with {
            $0.participantIdentity = participant.stringValue
            configure(&$0)
        }
        coordinator.handleIncoming(packet, serialized: nil, encryptionType: encryptionType)
    }
}

// MARK: - Payload cap

extension IncomingStreamManagerTests {
    /// A cap of zero reaches the core as zero, not as the built-in cap, so a one-byte stream fails.
    @Test func zeroPayloadCapRejectsNonEmptyStream() async throws {
        try reconnect(maxPayloadByteLength: 0)
        let read = try readingTextStreams()
        await feedTextStream(chunks: ["a"])

        await #expect(throws: StreamError.payloadTooLarge) {
            try await read.wait()
        }
    }

    /// Replaces the connection, as a disconnect and a new connect do, with one whose incoming
    /// manager has the given payload cap.
    private func reconnect(maxPayloadByteLength: Int?) throws {
        let options = RoomOptions(dataStreamOptions: DataStreamOptions(maxPayloadByteLength: maxPayloadByteLength))
        let connection = ConnectionDependencies(idle: room._state.stage.idle, room: room, roomOptions: options)
        try room._state.mutate {
            _ = $0.stage.end()
            try $0.stage.begin(connection)
        }
    }
}
