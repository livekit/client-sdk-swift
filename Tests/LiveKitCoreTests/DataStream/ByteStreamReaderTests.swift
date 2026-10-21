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
        let (reader, manager) = try await openReader()
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

    @Test func readToFile() async throws {
        let (reader, manager) = try await openReader()
        let fileURL = try await reader.writeToFile()
        #expect(fileURL.lastPathComponent == reader.info.name)
        #expect(try Data(contentsOf: fileURL) == testPayload)
        _ = manager
    }

    /// Releasing the manager, as a disconnect does, fails a reader still waiting for its trailer, so
    /// `readAll()` can't return the chunks received so far as if they were the whole payload.
    @Test func releasingManagerFailsOpenReader() async throws {
        let reader = try await openReader(trailerReason: nil).0
        let error = try #require(await #expect(throws: StreamError.self) { try await reader.readAll() })
        guard case .abnormalEnd = error else {
            Issue.record("Expected .abnormalEnd, got \(error)")
            return
        }
    }

    /// The sender chooses the stored name, so a name that leaves the directory is refused before
    /// any file opens. An empty name from the sender means "no name", so it is not listed here.
    @Test(arguments: ["../escape.bin", "nested/escape.bin", "..", ".", "..\\escape.bin", "escape\u{0}.bin", "../\u{0301}escape.bin", "a\\\u{0301}b"])
    func writeToFileRejectsSenderName(_ fileName: String) async throws {
        let (reader, manager) = try await openReader(fileName: fileName)
        try await expectNothingWritten { directory in
            try await reader.writeToFile(in: directory)
        }
        _ = manager
    }

    @Test(arguments: ["../escape.bin", "nested/escape.bin", "..", ".", "", "..\\escape.bin", "escape\u{0}.bin", "../\u{0301}escape.bin", "a\\\u{0301}b"])
    func writeToFileRejectsNameOverride(_ fileName: String) async throws {
        let (reader, manager) = try await openReader()
        try await expectNothingWritten { directory in
            try await reader.writeToFile(in: directory, name: fileName)
        }
        _ = manager
    }

    /// UniFFI's async calls ignore Swift cancellation. A read waiting on a stream that has only its
    /// header must still return when its task is cancelled, with the room still connected.
    @Test(arguments: [false, true])
    func cancellingWaitingReadReturns(iterate: Bool) async throws {
        let (reader, manager) = try await openReader(chunks: [], trailerReason: nil)
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

    /// `readAll` reads chunk by chunk, so a cancel stops the collection: at most the chunk in flight
    /// is lost, and the rest of the stream can still be read. A whole-stream read in the core would
    /// keep the reader to itself until the stream ends and leave nothing to read.
    @Test func cancelledReadAllLeavesRestOfStream() async throws {
        let (reader, manager) = try await openReader(chunks: [], trailerReason: nil)
        let started = AsyncCompleter<Void>(label: "Read started", defaultTimeout: 5)
        let read = Task {
            started.resume(returning: ())
            return try await reader.readAll()
        }
        try await started.wait()
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }

        let chunk = Data(repeating: 0x7F, count: 64)
        for index in 0 ..< 3 {
            let streamChunk = Livekit_DataStream.Chunk.with {
                $0.streamID = reader.info.id
                $0.chunkIndex = UInt64(index)
                $0.content = chunk
            }
            feed(manager) { $0.streamChunk = streamChunk }
        }
        let trailer = Livekit_DataStream.Trailer.with { $0.streamID = reader.info.id }
        feed(manager) { $0.streamTrailer = trailer }

        var rest = Data()
        for try await received in reader {
            rest += received
        }
        #expect(rest.count >= 2 * chunk.count)
    }

    /// The copy runs in the caller's task, so a cancel ends `writeToFile` at once and the file stops
    /// growing, rather than an unstructured task finishing the file in the background.
    @Test func cancellingWriteToFileStops() async throws {
        let (reader, manager) = try await openReader(chunks: [testChunks[0]], trailerReason: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(name)

        let returned = AsyncCompleter<Error?>(label: "Cancelled write returned", defaultTimeout: 5)
        let write = Task {
            do {
                _ = try await reader.writeToFile(in: directory)
                returned.resume(returning: nil)
            } catch {
                returned.resume(returning: error)
            }
        }
        try await poll(for: "the first chunk on disk") {
            (try? Data(contentsOf: fileURL))?.count == testChunks[0].count
        }
        write.cancel()

        #expect(try await returned.wait() is CancellationError)
        #expect(try Data(contentsOf: fileURL) == testChunks[0])
        _ = manager
    }

    @Test func info() async throws {
        let (reader, manager) = try await openReader()
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
    /// through a completer, which fails after a timeout instead of hanging.
    private final class Capture: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let opened = AsyncCompleter<LiveKit.ByteStreamReader>(label: "Stream opened", defaultTimeout: 10)

        func onByteStreamOpened(reader: LiveKitFFI.ByteStreamReader, identity _: String) {
            let info = LiveKit.ByteStreamInfo(reader.info(), encryptionType: .none)
            let publicReader = LiveKit.ByteStreamReader(reader, info: info)
            opened.resume(returning: publicReader)
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
    ) async throws -> (LiveKit.ByteStreamReader, IncomingDataStreamManager) {
        let capture = Capture()
        let manager = IncomingDataStreamManager(delegate: capture, maxPayloadByteLength: nil)
        let streamID = UUID().uuidString

        let header = Livekit_DataStream.Header.with {
            $0.streamID = streamID
            $0.topic = topic
            $0.mimeType = mimeType
            $0.contentHeader = .byteHeader(.with { $0.name = Self.withoutNUL(fileName ?? name) })
        }
        feed(manager, wireName: fileName ?? name) { $0.streamHeader = header }

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
        return try await (capture.opened.wait(), manager)
    }

    /// Runs `write` against a fresh directory and expects it to throw before creating anything,
    /// inside the directory or next to it.
    private func expectNothingWritten(_ write: (URL) async throws -> URL) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        await #expect(throws: StreamError.invalidFileName) {
            _ = try await write(directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["target"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// nanopb stores strings NUL-terminated, so a name with a NUL is encoded with a one-byte
    /// placeholder in its place, and ``feed(_:wireName:_:)`` puts the NUL on the wire afterwards.
    private static func withoutNUL(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{0}", with: "\u{1}")
    }

    private func feed(
        _ manager: IncomingDataStreamManager,
        wireName: String? = nil,
        _ configure: (inout Livekit_DataPacket.Builder) -> Void,
    ) {
        let packet = Livekit_DataPacket.with {
            $0.participantIdentity = "someName"
            configure(&$0)
        }
        guard var data = try? packet.serializedData() else { return }
        if let wireName, let range = data.range(of: Data(Self.withoutNUL(wireName).utf8)) {
            data.replaceSubrange(range, with: Data(wireName.utf8))
        }
        manager.handlePacketReceived(packet: data, encryptionType: .none)
    }
}
