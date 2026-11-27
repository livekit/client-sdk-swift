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
import LiveKitFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Exercises every ``TextStreamReader`` interface (iterating, `readAll()`) over an in-memory core
/// reader that replays chunks and an end reason.
@Suite(.tags(.dataStream))
struct TextStreamReaderTests {
    private let topic = "someTopic"

    private let testChunks = [
        String(repeating: "A", count: 128),
        String(repeating: "B", count: 128),
        String(repeating: "C", count: 256),
        String(repeating: "D", count: 32),
    ]

    /// All chunks combined.
    private var testPayload: String {
        testChunks.reduce("") { $0 + $1 }
    }

    @Test func chunkRead() async throws {
        let (reader, manager) = try await openReader()
        // The reader may deliver chunks with different boundaries than they were sent, so validate
        // the reassembled payload rather than a one-to-one chunk correspondence.
        var received = ""
        for try await chunk in reader {
            received += chunk
        }
        #expect(received == testPayload)
        _ = manager
    }

    @Test func chunkReadError() async throws {
        let (reader, manager) = try await openReader(trailerReason: "test")
        await #expect(throws: StreamError.abnormalEnd(reason: "test")) {
            for try await _ in reader {}
        }
        _ = manager
    }

    @Test func readAll() async throws {
        let (reader, manager) = try await openReader()
        let fullPayload = try await reader.readAll()
        #expect(fullPayload == testPayload)
        _ = manager
    }

    @Test func readAllOfEmptyStream() async throws {
        let (reader, manager) = try await openReader(chunks: [])
        #expect(try await reader.readAll().isEmpty)
        _ = manager
    }

    /// Once the stream has ended, the iterator keeps returning `nil`.
    @Test func nextAfterEndIsNil() async throws {
        let (reader, manager) = try await openReader()
        var chunks = reader.makeAsyncIterator()
        while try await chunks.next() != nil {}
        #expect(try await chunks.next() == nil)
        _ = manager
    }

    @Test func info() async throws {
        let (reader, manager) = try await openReader()
        #expect(reader.info.topic == topic)
        #expect(reader.info.operationType == .create)
        _ = manager
    }

    // MARK: - Helpers

    /// Opens a public reader over an in-memory core reader. The second value keeps the core alive,
    /// as the removed manager was kept alive. A `nil` reason leaves the stream open.
    private func openReader(
        chunks: [String]? = nil,
        trailerReason: String? = "",
    ) async throws -> (LiveKit.TextStreamReader, FakeTextReader) {
        let info = LiveKitFFI.TextStreamInfo(id: UUID().uuidString, topic: topic, timestampMs: 0, totalLength: nil,
                                             attributes: [:], mimeType: "text/plain", operationType: .create, version: 0,
                                             replyToStreamId: nil, attachedStreamIds: [], generated: false, encryptionType: .none)
        let core = FakeTextReader(info: info, chunks: chunks ?? testChunks, endReason: trailerReason)
        return (LiveKit.TextStreamReader(core), core)
    }
}
