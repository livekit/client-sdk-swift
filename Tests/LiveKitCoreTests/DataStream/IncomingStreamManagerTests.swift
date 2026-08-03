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

// swiftlint:disable file_length

import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.dataStream))
struct IncomingStreamManagerTests: @unchecked Sendable {
    private var manager: IncomingStreamManager

    private let topicName = "someTopic"
    private let participant = Participant.Identity(from: "someName")

    init() {
        manager = IncomingStreamManager()
    }

    @Test func registerByteHandler() async throws {
        try await manager.registerByteStreamHandler(for: topicName) { _, _ in }

        await confirmation("Throws on duplicate registration") { confirm in
            do {
                try await manager.registerByteStreamHandler(for: topicName) { _, _ in }
            } catch {
                #expect(error as? StreamError == .handlerAlreadyRegistered)
                confirm()
            }
        }

        await manager.unregisterByteStreamHandler(for: topicName)
    }

    @Test func registerTextHandler() async throws {
        try await manager.registerTextStreamHandler(for: topicName) { _, _ in }

        await confirmation("Throws on duplicate registration") { confirm in
            do {
                try await manager.registerTextStreamHandler(for: topicName) { _, _ in }
            } catch {
                #expect(error as? StreamError == .handlerAlreadyRegistered)
                confirm()
            }
        }

        await manager.unregisterTextStreamHandler(for: topicName)
    }

    @Test func byteStream() async throws {
        try await confirmation("Receives payload") { confirm in
            let testChunks = [
                Data(repeating: 0xAB, count: 128),
                Data(repeating: 0xCD, count: 128),
                Data(repeating: 0xEF, count: 256),
                Data(repeating: 0x12, count: 32),
            ]
            let testPayload = testChunks.reduce(Data()) { $0 + $1 }

            try await manager.registerByteStreamHandler(for: topicName) { reader, participant in
                #expect(participant == self.participant)
                let payload = try await reader.readAll()
                #expect(payload == testPayload)
                confirm()
            }

            await sendByteStream(chunks: testChunks)
        }
    }

    @Test func textStream() async throws {
        try await confirmation("Receives payload") { confirm in
            let testChunks = [
                String(repeating: "A", count: 128),
                String(repeating: "B", count: 128),
                String(repeating: "C", count: 256),
                String(repeating: "D", count: 32),
            ]
            let testPayload = testChunks.reduce("") { $0 + $1 }

            try await manager.registerTextStreamHandler(for: topicName) { reader, participant in
                #expect(participant == self.participant)
                let payload = try await reader.readAll()
                #expect(payload == testPayload)
                confirm()
            }

            await sendTextStream(chunks: testChunks)
        }
    }

    @Test func nonTextData() async throws {
        try await confirmation("Throws error on non-text data") { confirm in
            let testPayload = Data(repeating: 0xAB, count: 128)

            try await manager.registerTextStreamHandler(for: topicName) { reader, _ in
                do {
                    _ = try await reader.readAll()
                } catch {
                    #expect(error as? StreamError == .decodeFailed)
                    confirm()
                }
            }

            await sendTextStream(rawPayload: testPayload, totalLength: UInt64(testPayload.count))
        }
    }

    @Test func abnormalClosure() async throws {
        try await confirmation("Throws error on abnormal closure") { confirm in
            let closureReason = "test"

            try await manager.registerByteStreamHandler(for: topicName) { reader, _ in
                do {
                    _ = try await reader.readAll()
                } catch {
                    #expect(error as? StreamError == .abnormalEnd(reason: closureReason))
                    confirm()
                }
            }

            let streamID = UUID().uuidString

            var header = Livekit_DataStream.Header()
            header.streamID = streamID
            header.topic = topicName
            header.contentHeader = .byteHeader(Livekit_DataStream.ByteHeader())
            manager.handle(.header(header, participant.stringValue, .none))

            var trailer = Livekit_DataStream.Trailer()
            trailer.streamID = streamID
            trailer.reason = closureReason
            manager.handle(.trailer(trailer, .none))

            // Handler processes asynchronously — give it time to complete
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    c.resume()
                }
            }
        }
    }

    @Test func incomplete() async throws {
        try await confirmation("Throws error on incomplete stream") { confirm in
            let testPayload = Data(repeating: 0xAB, count: 128)

            try await manager.registerByteStreamHandler(for: topicName) { reader, _ in
                do {
                    _ = try await reader.readAll()
                } catch {
                    #expect(error as? StreamError == .incomplete)
                    confirm()
                }
            }

            let streamID = UUID().uuidString

            var header = Livekit_DataStream.Header()
            header.streamID = streamID
            header.topic = topicName
            header.contentHeader = .byteHeader(Livekit_DataStream.ByteHeader())
            header.totalLength = UInt64(testPayload.count + 10) // expect more bytes
            manager.handle(.header(header, participant.stringValue, .none))

            var chunk = Livekit_DataStream.Chunk()
            chunk.streamID = streamID
            chunk.chunkIndex = 0
            chunk.content = Data(testPayload)
            manager.handle(.chunk(chunk, .none))

            var trailer = Livekit_DataStream.Trailer()
            trailer.streamID = streamID
            trailer.reason = ""
            manager.handle(.trailer(trailer, .none))

            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    c.resume()
                }
            }
        }
    }

    @Test func encryptionTypeMismatch() async throws {
        let manager = IncomingStreamManager()
        let topic = "test-encryption-mismatch"

        try await confirmation("Stream should receive error") { confirm in
            try await manager.registerByteStreamHandler(for: topic) { reader, _ in
                do {
                    _ = try await reader.readAll()
                } catch let error as StreamError {
                    if case let .encryptionTypeMismatch(expected, received) = error {
                        #expect(expected == .gcm)
                        #expect(received == .none)
                        confirm()
                    } else {
                        Issue.record("Expected encryptionTypeMismatch error, got \(error)")
                    }
                }
            }

            var header = Livekit_DataStream.Header()
            header.streamID = "test-stream-id"
            header.topic = topic
            header.mimeType = "application/octet-stream"
            header.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            header.contentHeader = .byteHeader(.with {
                $0.name = "test-file.bin"
            })
            manager.handle(.header(header, "test-participant", .gcm))

            var chunk = Livekit_DataStream.Chunk()
            chunk.streamID = "test-stream-id"
            chunk.chunkIndex = 0
            chunk.content = Data("test data".utf8)
            manager.handle(.chunk(chunk, .none))

            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    c.resume()
                }
            }
        }
    }

    // MARK: - Helpers

    private func sendByteStream(chunks: [Data]) async {
        let streamID = UUID().uuidString

        var header = Livekit_DataStream.Header()
        header.streamID = streamID
        header.topic = topicName
        header.contentHeader = .byteHeader(Livekit_DataStream.ByteHeader())
        manager.handle(.header(header, participant.stringValue, .none))

        for (index, chunkData) in chunks.enumerated() {
            var chunk = Livekit_DataStream.Chunk()
            chunk.streamID = streamID
            chunk.chunkIndex = UInt64(index)
            chunk.content = chunkData
            manager.handle(.chunk(chunk, .none))
        }

        var trailer = Livekit_DataStream.Trailer()
        trailer.streamID = streamID
        trailer.reason = ""
        manager.handle(.trailer(trailer, .none))

        // Handler processes asynchronously — give it time to complete
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                c.resume()
            }
        }
    }

    private func sendTextStream(chunks: [String]? = nil, rawPayload: Data? = nil, totalLength: UInt64? = nil, streamID: String = UUID().uuidString, settle: Bool = true) async {
        var header = Livekit_DataStream.Header()
        header.streamID = streamID
        header.topic = topicName
        header.contentHeader = .textHeader(Livekit_DataStream.TextHeader())
        if let totalLength { header.totalLength = totalLength }
        manager.handle(.header(header, participant.stringValue, .none))

        if let chunks {
            for (index, chunkData) in chunks.enumerated() {
                var chunk = Livekit_DataStream.Chunk()
                chunk.streamID = streamID
                chunk.chunkIndex = UInt64(index)
                chunk.content = Data(chunkData.utf8)
                manager.handle(.chunk(chunk, .none))
            }
        } else if let rawPayload {
            var chunk = Livekit_DataStream.Chunk()
            chunk.streamID = streamID
            chunk.chunkIndex = 0
            chunk.content = rawPayload
            manager.handle(.chunk(chunk, .none))
        }

        var trailer = Livekit_DataStream.Trailer()
        trailer.streamID = streamID
        trailer.reason = ""
        manager.handle(.trailer(trailer, .none))

        guard settle else { return }
        // Handler processes asynchronously — give it time to complete
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                c.resume()
            }
        }
    }
}

/// One-shot latch: `wait()` suspends until `open()`; waiters after `open()` pass through.
private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters = []
        for continuation in continuations {
            continuation.resume()
        }
    }
}

extension IncomingStreamManagerTests {
    /// `handle(_:)` only enqueues onto the manager's event loop, so tests that
    /// call cleanup APIs directly must first wait for the events to be processed.
    private func waitForOpenStreams(_ count: Int) async {
        let deadline = Date().addingTimeInterval(10)
        while await manager.openStreamCount < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func sendTextHeader(streamID: String) async {
        var header = Livekit_DataStream.Header()
        header.streamID = streamID
        header.topic = topicName
        header.contentHeader = .textHeader(Livekit_DataStream.TextHeader())
        manager.handle(.header(header, participant.stringValue, .none))
    }

    private func sendTextChunk(streamID: String, content: String) async {
        var chunk = Livekit_DataStream.Chunk()
        chunk.streamID = streamID
        chunk.content = Data(content.utf8)
        manager.handle(.chunk(chunk, .none))
    }

    private func sendTextTrailer(streamID: String) async {
        var trailer = Livekit_DataStream.Trailer()
        trailer.streamID = streamID
        manager.handle(.trailer(trailer, .none))
    }

    /// Senders may reuse one stream ID for consecutive streams (each `sendText`
    /// in a transcription segment does). Descriptor cleanup used to run in the
    /// reader's `onTermination` task, which raced the reopening header and made
    /// `openStream` silently drop the new stream.
    @Test func reusedStreamIDDeliversEveryStream() async throws {
        let payloads = ["one", "two", "three"]
        let received = StateSync<[String]>([])

        try await manager.registerTextStreamHandler(for: topicName) { reader, _ in
            let payload = try await reader.readAll()
            received.mutate { $0.append(payload) }
        }

        // Back-to-back, no settling between streams: the reopening header must
        // hit the event loop while the previous stream's cleanup could still be
        // pending.
        let streamID = UUID().uuidString
        for payload in payloads {
            await sendTextStream(chunks: [payload], streamID: streamID, settle: false)
        }

        let deadline = Date().addingTimeInterval(10)
        while received.copy().count < payloads.count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(received.copy().sorted() == payloads.sorted())
        await manager.unregisterTextStreamHandler(for: topicName)
    }

    /// A stream failing mid-flight (here: exceeding its declared length) must not
    /// block a new stream that immediately reuses the same stream ID.
    @Test func reusedStreamIDAfterChunkErrorDeliversNextStream() async throws {
        let received = StateSync<[String]>([])

        try await manager.registerTextStreamHandler(for: topicName) { reader, _ in
            let payload = try await reader.readAll()
            received.mutate { $0.append(payload) }
        }

        let streamID = UUID().uuidString
        // 8-byte chunk against a declared total of 4 → lengthExceeded.
        await sendTextStream(rawPayload: Data("ABCDEFGH".utf8), totalLength: 4, streamID: streamID, settle: false)
        await sendTextStream(chunks: ["ok"], streamID: streamID, settle: false)

        let deadline = Date().addingTimeInterval(10)
        while received.copy().isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(received.copy() == ["ok"])
        await manager.unregisterTextStreamHandler(for: topicName)
    }

    /// Ordering must compose transitively: C waits on B even while B is itself
    /// still waiting on A. If the chain breaks, B and C complete while A's
    /// handler is gated and the order comes out wrong.
    @Test func orderedTopicChainsAcrossFinishingHandlers() async throws {
        let received = StateSync<[String]>([])
        let gate = TestGate()

        try await manager.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            let payload = try await reader.readAll()
            // First handler stalls after its stream closed, becoming a
            // still-finishing predecessor for the streams sent after it.
            if payload == "a" { await gate.wait() }
            received.mutate { $0.append(payload) }
        }

        for payload in ["a", "b", "c"] {
            await sendTextStream(chunks: [payload], settle: false)
        }
        await gate.open()

        let deadline = Date().addingTimeInterval(10)
        while received.copy().count < 3, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(received.copy() == ["a", "b", "c"])
        await manager.unregisterTextStreamHandler(for: topicName)
    }

    /// A still-open stream must not delay streams that overlap with it on the
    /// wire (e.g. a user's live transcript arriving while an agent's message
    /// stream is still open). Ordering applies only to non-overlapping streams.
    @Test func orderedTopicDoesNotDelayOverlappingStreams() async throws {
        let received = StateSync<[String]>([])

        try await manager.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            let payload = try await reader.readAll()
            received.mutate { $0.append(payload) }
        }

        // Stream A opens and stays open; stream B opens, delivers, and closes
        // while A is still open — B's handler must complete without waiting.
        await sendTextHeader(streamID: "open-a")
        await sendTextChunk(streamID: "open-a", content: "a")
        await sendTextStream(chunks: ["b"], streamID: "b", settle: false)

        var deadline = Date().addingTimeInterval(10)
        while received.copy().isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(received.copy() == ["b"])

        // A still completes normally once its trailer arrives.
        await sendTextTrailer(streamID: "open-a")
        deadline = Date().addingTimeInterval(10)
        while received.copy().count < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(received.copy() == ["b", "a"])
        await manager.unregisterTextStreamHandler(for: topicName)
    }

    /// A sender disconnecting before its trailer leaves the stream open forever;
    /// `closeStreams(from:)` must fail it so an ordered topic's queue drains.
    @Test func closeStreamsUnblocksOrderedTopic() async throws {
        let received = StateSync<[String]>([])
        let errors = StateSync<[StreamError]>([])

        try await manager.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            do {
                let payload = try await reader.readAll()
                received.mutate { $0.append(payload) }
            } catch let error as StreamError {
                errors.mutate { $0.append(error) }
                throw error
            }
        }

        // Header only — no trailer ever arrives, so the handler blocks in readAll
        // and, at the head of the ordered queue, would block every later stream.
        await sendTextHeader(streamID: "orphan")
        await waitForOpenStreams(1)

        await manager.closeStreams(from: participant)
        await sendTextStream(chunks: ["after"], settle: false)

        let deadline = Date().addingTimeInterval(10)
        while received.copy().isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(received.copy() == ["after"])
        #expect(errors.copy() == [.terminated])
        await manager.unregisterTextStreamHandler(for: topicName)
    }

    /// Same shape as above via the room-lifecycle path: `reset()` fails all open
    /// streams but keeps handlers registered for after a reconnect.
    @Test func resetUnblocksOrderedTopicAndKeepsHandler() async throws {
        let received = StateSync<[String]>([])

        try await manager.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            let payload = try await reader.readAll()
            received.mutate { $0.append(payload) }
        }

        await sendTextHeader(streamID: "orphan")
        await waitForOpenStreams(1)

        await manager.reset()
        await sendTextStream(chunks: ["after-reset"], settle: false)

        let deadline = Date().addingTimeInterval(10)
        while received.copy().isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(received.copy() == ["after-reset"])
        await manager.unregisterTextStreamHandler(for: topicName)
    }

    /// Handlers for an `ordered` topic must observe streams in wire order, not
    /// the scheduling order of independently spawned handler tasks.
    @Test func orderedTopicDeliversStreamsInOrder() async throws {
        let count = 16
        let received = StateSync<[String]>([])

        try await manager.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            let payload = try await reader.readAll()
            received.mutate { $0.append(payload) }
        }

        for index in 0 ..< count {
            await sendTextStream(chunks: ["payload-\(index)"], settle: false)
        }

        let deadline = Date().addingTimeInterval(10)
        while received.copy().count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(received.copy() == (0 ..< count).map { "payload-\($0)" })
        await manager.unregisterTextStreamHandler(for: topicName)
    }
}
