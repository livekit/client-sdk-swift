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

    /// Releasing the manager, as a disconnect does, fails a reader still waiting for its trailer, so
    /// `readAll()` can't return the chunks received so far as if they were the whole payload.
    @Test func releasingManagerFailsOpenReader() async throws {
        let reader = await openReader(trailerReason: nil).0
        let error = try #require(await #expect(throws: StreamError.self) { try await reader.readAll() })
        guard case .abnormalEnd = error else {
            Issue.record("Expected .abnormalEnd, got \(error)")
            return
        }
    }

    /// The sender chooses the stored name, so a name that leaves the directory is refused before
    /// any file opens. An empty name from the sender means "no name", so it is not listed here.
    @Test(arguments: ["../escape.bin", "nested/escape.bin", "..", "."])
    func writeToFileRejectsSenderName(_ fileName: String) async throws {
        let (reader, manager) = await openReader(fileName: fileName)
        try await expectNothingWritten { directory in
            try await reader.writeToFile(in: directory)
        }
        _ = manager
    }

    @Test(arguments: ["../escape.bin", "nested/escape.bin", "..", ".", ""])
    func writeToFileRejectsNameOverride(_ fileName: String) async throws {
        let (reader, manager) = await openReader()
        try await expectNothingWritten { directory in
            try await reader.writeToFile(in: directory, name: fileName)
        }
        _ = manager
    }

    /// UniFFI's async calls ignore Swift cancellation. A read waiting on a stream that has only its
    /// header must still return when its task is cancelled, with the room still connected.
    @Test(arguments: [false, true])
    func cancellingWaitingReadReturns(iterate: Bool) async throws {
        let (reader, manager) = await openReader(chunks: [], trailerReason: nil)
        let returned = AsyncCompleter<Error?>(label: "Cancelled read returned", defaultTimeout: 5)

        let read = Task {
            do {
                if iterate {
                    for try await _ in reader {}
                } else {
                    _ = try await reader.readAll()
                }
                returned.resume(returning: nil)
            } catch {
                returned.resume(returning: error)
            }
        }
        // Lets the read reach the FFI wait. If it has not yet, the cancel ends it the same way.
        try await Task.sleep(nanoseconds: 100_000_000)
        read.cancel()

        let error = try await returned.wait()
        #expect(error is CancellationError)
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

        func onByteStreamOpened(reader: LiveKitFFI.ByteStreamReader, identity _: String) {
            let info = LiveKit.ByteStreamInfo(reader.info(), encryptionType: .none)
            let publicReader = LiveKit.ByteStreamReader(reader, info: info)
            let continuation = pending.mutate { current -> CheckedContinuation<LiveKit.ByteStreamReader, Never>? in
                defer { current = nil }
                return current
            }
            continuation?.resume(returning: publicReader)
        }

        func onTextStreamOpened(reader _: LiveKitFFI.TextStreamReader, identity _: String) {}

        func onStreamClosed(streamId _: String, identity _: String) {}
    }

    /// Opens a byte stream through the FFI incoming manager and returns the public reader plus the
    /// manager, which the caller must keep alive while reading. A `nil` reason leaves the stream
    /// open by sending no trailer.
    private func openReader(
        fileName: String? = nil,
        chunks: [Data]? = nil,
        trailerReason: String? = "",
    ) async -> (LiveKit.ByteStreamReader, IncomingDataStreamManager) {
        let capture = Capture()
        let manager = IncomingDataStreamManager(delegate: capture, maxPayloadByteLength: nil)
        let streamID = UUID().uuidString

        let reader = await withCheckedContinuation { (continuation: CheckedContinuation<LiveKit.ByteStreamReader, Never>) in
            capture.pending.mutate { $0 = continuation }

            let header = Livekit_DataStream.Header.with {
                $0.streamID = streamID
                $0.topic = topic
                $0.mimeType = mimeType
                $0.contentHeader = .byteHeader(.with { $0.name = fileName ?? name })
            }
            feed(manager) { $0.streamHeader = header }

            for (index, chunk) in (chunks ?? testChunks).enumerated() {
                let streamChunk = Livekit_DataStream.Chunk.with {
                    $0.streamID = streamID
                    $0.chunkIndex = UInt64(index)
                    $0.content = chunk
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
        }
        return (reader, manager)
    }

    /// Runs `write` against a fresh directory and expects it to throw before creating anything,
    /// inside the directory or next to it.
    private func expectNothingWritten(_ write: (URL) async throws -> URL) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        await #expect(throws: StreamError.fileInfoUnavailable) {
            _ = try await write(directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["target"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
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
