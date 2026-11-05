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

/// Exercises every ``TextStreamReader`` interface (iterating, `readAll()`) against a reader minted by
/// the UniFFI incoming manager: a real `IncomingDataStreamManager` is fed data stream packets, the
/// opened reader is captured, and its contents are read back through each API.
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

    /// The info reads the core's: the header's attributes until the trailer arrives, and then also
    /// the trailer's, which replace header attributes with the same key.
    @Test func infoShowsTrailerAttributesAfterTheEnd() async throws {
        let (reader, manager) = try await openReader(trailerReason: nil, headerAttributes: ["kept": "header", "replaced": "header"])
        #expect(reader.info.attributes == ["kept": "header", "replaced": "header"])

        feed(manager) {
            $0.streamTrailer = Livekit_DataStream.Trailer.with {
                $0.streamID = reader.info.id
                $0.attributes = ["replaced": "trailer", "added": "trailer"]
            }
        }
        _ = try await reader.readAll()
        #expect(reader.info.attributes == ["kept": "header", "replaced": "trailer", "added": "trailer"])
        _ = manager
    }

    // MARK: - Helpers

    /// Delegate that wraps the FFI reader into the public ``TextStreamReader`` and hands it back
    /// through a completer, which fails after a timeout instead of hanging.
    private final class Capture: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let opened = AsyncCompleter<LiveKit.TextStreamReader>(label: "Stream opened", defaultTimeout: 10)

        func onByteStreamOpened(reader _: LiveKitFFI.ByteStreamReader, identity _: String) {}

        func onStreamClosed(streamId _: String, identity _: String) {}

        func onTextStreamOpened(reader: LiveKitFFI.TextStreamReader, identity _: String) {
            opened.resume(returning: LiveKit.TextStreamReader(reader))
        }
    }

    /// Opens a text stream through the FFI incoming manager and returns the public reader plus the
    /// manager, which the caller must keep alive while reading. A `nil` reason leaves the stream
    /// open by sending no trailer.
    private func openReader(
        chunks: [String]? = nil,
        trailerReason: String? = "",
        headerAttributes: [String: String] = [:],
    ) async throws -> (LiveKit.TextStreamReader, IncomingDataStreamManager) {
        let capture = Capture()
        let manager = IncomingDataStreamManager(delegate: capture, maxPayloadByteLength: nil)
        let streamID = UUID().uuidString

        let header = Livekit_DataStream.Header.with {
            $0.streamID = streamID
            $0.topic = topic
            $0.attributes = headerAttributes
            $0.contentHeader = .textHeader(Livekit_DataStream.TextHeader())
        }
        feed(manager) { $0.streamHeader = header }

        for (index, chunk) in (chunks ?? testChunks).enumerated() {
            let streamChunk = Livekit_DataStream.Chunk.with {
                $0.streamID = streamID
                $0.chunkIndex = UInt64(index)
                $0.content = Data(chunk.utf8)
            }
            feed(manager) { $0.streamChunk = streamChunk }
        }

        if let trailerReason {
            let trailer = Livekit_DataStream.Trailer.with {
                $0.streamID = streamID
                $0.reason = trailerReason
            }
            feed(manager) { $0.streamTrailer = trailer }
        }
        return try await (capture.opened.wait(), manager)
    }

    private func feed(_ manager: IncomingDataStreamManager, _ configure: (inout Livekit_DataPacket.Builder) -> Void) {
        let packet = Livekit_DataPacket.with {
            $0.participantIdentity = "someName"
            configure(&$0)
        }
        guard let data = try? packet.serializedData() else { return }
        manager.handlePacketReceived(packet: data, encryptionType: .none)
    }
}
