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
import LiveKitUniFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Exercises every ``ByteStreamReader`` interface (iterating, `readAll()`, `writeToFile()`) against
/// a reader minted by the UniFFI incoming manager: a real `IncomingDataStreamManager` is fed data
/// stream packets, the opened reader is captured, and its contents are read back through each API.
@Suite(.tags(.dataStream))
struct ByteStreamReaderTests {
    private let topic = "someTopic"
    private let name = "filename.bin"
    private let mimeType = "application/octet-stream"

    private let testChunks = [
        Data(repeating: 0xAB, count: 128),
        Data(repeating: 0xCD, count: 128),
        Data(repeating: 0xEF, count: 256),
        Data(repeating: 0x12, count: 32),
    ]

    /// All chunks combined.
    private var testPayload: Data {
        testChunks.reduce(Data()) { $0 + $1 }
    }

    @Test func chunkRead() async throws {
        let (reader, manager) = await openReader()
        // The reader may deliver chunks with different boundaries than they were sent, so validate
        // the reassembled payload rather than a one-to-one chunk correspondence.
        var received = Data()
        for try await chunk in reader {
            received += chunk
        }
        #expect(received == testPayload)
        _ = manager
    }

    @Test func chunkReadError() async throws {
        let (reader, manager) = await openReader(trailerReason: "test")
        await #expect(throws: StreamError.abnormalEnd(reason: "test")) {
            for try await _ in reader {}
        }
        _ = manager
    }

    @Test func readAll() async throws {
        let (reader, manager) = await openReader()
        let fullPayload = try await reader.readAll()
        #expect(fullPayload == testPayload)
        _ = manager
    }

    @Test func readToFile() async throws {
        let (reader, manager) = await openReader()
        let fileURL = try await reader.writeToFile()
        #expect(fileURL.lastPathComponent == reader.info.name)
        #expect(try Data(contentsOf: fileURL) == testPayload)
        _ = manager
    }

    @Test func info() async {
        let (reader, manager) = await openReader()
        #expect(reader.info.topic == topic)
        #expect(reader.info.name == name)
        #expect(reader.info.mimeType == mimeType)
        _ = manager
    }

    // MARK: - Static filename resolution (no FFI)

    struct FileNameCase: CustomTestStringConvertible {
        let preferred: String?
        let fallback: String
        let mimeType: String
        let expected: String
        var testDescription: String { "preferred=\(preferred ?? "nil"), mime=\(mimeType) → \(expected)" }
    }

    @Test(arguments: [
        FileNameCase(preferred: nil, fallback: "[fallback]", mimeType: "text/plain", expected: "[fallback].txt"),
        FileNameCase(preferred: "name", fallback: "[fallback]", mimeType: "text/plain", expected: "name.txt"),
        FileNameCase(preferred: "name.jpeg", fallback: "[fallback]", mimeType: "text/plain", expected: "name.jpeg"),
        FileNameCase(preferred: "name", fallback: "[fallback]", mimeType: "image/jpeg", expected: "name.jpeg"),
        FileNameCase(preferred: "name", fallback: "[fallback]", mimeType: "text/invalid", expected: "name.bin"),
    ])
    func resolveFileName(_ c: FileNameCase) {
        #expect(
            LiveKit.ByteStreamReader.resolveFileName(
                preferredName: c.preferred,
                fallbackName: c.fallback,
                mimeType: c.mimeType,
            ) == c.expected,
        )
    }

    // MARK: - Helpers

    /// Delegate that wraps the FFI reader into the public ``ByteStreamReader`` and hands it back
    /// through a continuation.
    private final class Capture: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let pending = StateSync<CheckedContinuation<LiveKit.ByteStreamReader, Never>?>(nil)

        func onByteStreamOpened(reader: LiveKitUniFFI.ByteStreamReader, identity _: String) {
            let info = LiveKit.ByteStreamInfo(reader.info(), encryptionType: .none)
            let publicReader = LiveKit.ByteStreamReader(reader, info: info)
            let continuation = pending.mutate { current -> CheckedContinuation<LiveKit.ByteStreamReader, Never>? in
                defer { current = nil }
                return current
            }
            continuation?.resume(returning: publicReader)
        }

        func onTextStreamOpened(reader _: LiveKitUniFFI.TextStreamReader, identity _: String) {}

        func onStreamClosed(streamId _: String, identity _: String) {}
    }

    /// Opens a byte stream through the FFI incoming manager and returns the public reader plus the
    /// manager, which the caller must keep alive while reading.
    private func openReader(trailerReason: String = "") async -> (LiveKit.ByteStreamReader, IncomingDataStreamManager) {
        let capture = Capture()
        let manager = IncomingDataStreamManager(delegate: capture, maxPayloadByteLength: nil)
        let streamID = UUID().uuidString

        let reader = await withCheckedContinuation { (continuation: CheckedContinuation<LiveKit.ByteStreamReader, Never>) in
            capture.pending.mutate { $0 = continuation }

            let header = Livekit_DataStream.Header.with {
                $0.streamID = streamID
                $0.topic = topic
                $0.mimeType = mimeType
                $0.contentHeader = .byteHeader(.with { $0.name = name })
            }
            feed(manager) { $0.streamHeader = header }

            for (index, chunk) in testChunks.enumerated() {
                let streamChunk = Livekit_DataStream.Chunk.with {
                    $0.streamID = streamID
                    $0.chunkIndex = UInt64(index)
                    $0.content = chunk
                }
                feed(manager) { $0.streamChunk = streamChunk }
            }

            let trailer = Livekit_DataStream.Trailer.with {
                $0.streamID = streamID
                $0.reason = trailerReason
            }
            feed(manager) { $0.streamTrailer = trailer }
        }
        return (reader, manager)
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
