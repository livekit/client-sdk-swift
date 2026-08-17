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

    init() {
        room = Room()
        coordinator = DataStreams(room: room)
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

        let payload: Data = try await withCheckedThrowingContinuation { continuation in
            do {
                try coordinator.registerByteStreamHandler(for: topicName) { reader, participant in
                    #expect(participant == self.participant)
                    do {
                        try await continuation.resume(returning: reader.readAll())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
                return
            }
            Task { await feedByteStream(chunks: testChunks) }
        }

        #expect(payload == testPayload)
    }

    @Test func textStream() async throws {
        let testChunks = [
            String(repeating: "A", count: 128),
            String(repeating: "B", count: 128),
            String(repeating: "C", count: 256),
            String(repeating: "D", count: 32),
        ]
        let testPayload = testChunks.reduce("") { $0 + $1 }

        let payload: String = try await withCheckedThrowingContinuation { continuation in
            do {
                try coordinator.registerTextStreamHandler(for: topicName) { reader, participant in
                    #expect(participant == self.participant)
                    do {
                        try await continuation.resume(returning: reader.readAll())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
                return
            }
            Task { await feedTextStream(chunks: testChunks) }
        }

        #expect(payload == testPayload)
    }

    @Test func nonTextData() async throws {
        // A text stream carrying non-UTF-8 bytes surfaces `.decodeFailed` when read.
        let rawPayload = Data(repeating: 0xAB, count: 128)

        await #expect(throws: StreamError.decodeFailed) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                do {
                    try coordinator.registerTextStreamHandler(for: topicName) { reader, _ in
                        do {
                            try await continuation.resume(returning: reader.readAll())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                Task { await self.feedTextStream(rawPayload: rawPayload) }
            }
        }
    }

    @Test func abnormalClosure() async {
        let closureReason = "test"

        let error = await byteReaderError { streamID in
            feedHeader(streamID: streamID, byte: true)
            feedTrailer(streamID: streamID, reason: closureReason)
        }

        #expect(error as? StreamError == .abnormalEnd(reason: closureReason))
    }

    @Test func incomplete() async {
        let testPayload = Data(repeating: 0xAB, count: 128)

        let error = await byteReaderError { streamID in
            feedHeader(streamID: streamID, byte: true, totalLength: UInt64(testPayload.count + 10))
            feedChunk(streamID: streamID, index: 0, content: testPayload)
            feedTrailer(streamID: streamID, reason: "")
        }

        #expect(error as? StreamError == .incomplete)
    }

    // Note: the v1 `encryptionTypeMismatch` behavior is intentionally not ported. Data-stream
    // encryption is now applied transparently at the `DataChannelPair` layer and the UniFFI boundary
    // normalizes the per-packet encryption type, so a header/chunk mismatch can no longer occur here.

    // MARK: - Helpers

    /// Registers a byte handler, feeds a stream via `feed(streamID:)`, and returns the error the
    /// reader's `readAll()` throws (or `nil` on success). The continuation makes the wait
    /// deterministic without relying on sleeps.
    private func byteReaderError(feeding feed: @escaping @Sendable (String) -> Void) async -> Error? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            do {
                try coordinator.registerByteStreamHandler(for: topicName) { reader, _ in
                    do {
                        _ = try await reader.readAll()
                        continuation.resume(returning: nil)
                    } catch {
                        continuation.resume(returning: error)
                    }
                }
            } catch {
                continuation.resume(returning: error)
                return
            }
            Task { feed(UUID().uuidString) }
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

    func feedHeader(streamID: String, byte: Bool, totalLength: UInt64? = nil) {
        let header = Livekit_DataStream.Header.with {
            $0.streamID = streamID
            $0.topic = topicName
            $0.contentHeader = byte
                ? .byteHeader(Livekit_DataStream.ByteHeader())
                : .textHeader(Livekit_DataStream.TextHeader())
            if let totalLength { $0.totalLength = totalLength }
        }
        feed { $0.streamHeader = header }
    }

    func feedChunk(streamID: String, index: UInt64, content: Data) {
        let chunk = Livekit_DataStream.Chunk.with {
            $0.streamID = streamID
            $0.chunkIndex = index
            $0.content = content
        }
        feed { $0.streamChunk = chunk }
    }

    func feedTrailer(streamID: String, reason: String) {
        let trailer = Livekit_DataStream.Trailer.with {
            $0.streamID = streamID
            $0.reason = reason
        }
        feed { $0.streamTrailer = trailer }
    }

    private func feed(_ configure: (inout Livekit_DataPacket.Builder) -> Void) {
        let packet = Livekit_DataPacket.with {
            $0.participantIdentity = participant.stringValue
            configure(&$0)
        }
        coordinator.handleIncoming(packet)
    }
}
