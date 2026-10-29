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
    let topic = "someTopic"
    let name = "filename.bin"
    let mimeType = "application/octet-stream"

    let testChunks = [
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
        // A fresh directory per run: the destination is created exclusively, so a fixed name in
        // the shared temporary directory would collide with a previous run's file.
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (reader, manager) = try await openReader()
        let fileURL = try await reader.writeToFile(in: directory)
        #expect(fileURL.lastPathComponent == reader.info.name)
        #expect(try Data(contentsOf: fileURL) == testPayload)
        _ = manager
    }

    /// The sender chooses the stored name, so an existing file must not be replaced by one.
    @Test func writeToFileDoesNotOverwriteExistingFile() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let victim = directory.appendingPathComponent(name)
        try Data("original".utf8).write(to: victim)

        let (reader, manager) = try await openReader()
        await #expect(throws: StreamError.self) {
            try await reader.writeToFile(in: directory)
        }
        #expect(try Data(contentsOf: victim) == Data("original".utf8))
        _ = manager
    }

    /// A symlink already at the destination must not be followed to its target.
    @Test func writeToFileDoesNotFollowSymlink() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("target.bin")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(name),
            withDestinationURL: target,
        )

        let (reader, manager) = try await openReader()
        await #expect(throws: StreamError.self) {
            try await reader.writeToFile(in: directory)
        }
        #expect(try Data(contentsOf: target) == Data("original".utf8))
        _ = manager
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
    final class Capture: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let opened = AsyncCompleter<LiveKit.ByteStreamReader>(label: "Stream opened", defaultTimeout: 10)
        let entered: AsyncCompleter<Void>?

        init(entered: AsyncCompleter<Void>?) {
            self.entered = entered
        }

        func onByteStreamOpened(reader: LiveKitFFI.ByteStreamReader, identity _: String) {
            let info = LiveKit.ByteStreamInfo(reader.info(), encryptionType: .none)
            let core: any LiveKitFFI.ByteStreamReaderProtocol = entered.map { SignallingReader(reader, entered: $0) } ?? reader
            opened.resume(returning: LiveKit.ByteStreamReader(core, info: info))
        }

        func onTextStreamOpened(reader _: LiveKitFFI.TextStreamReader, identity _: String) {}

        func onStreamClosed(streamId _: String, identity _: String) {}
    }

    /// Opens a byte stream through the FFI incoming manager and returns the public reader plus the
    /// manager, which the caller must keep alive while reading. A `nil` reason leaves the stream
    /// open by sending no trailer. With `entered`, the reader reports when a read enters the core.
    func openReader(
        fileName: String? = nil,
        chunks: [Data]? = nil,
        trailerReason: String? = "",
        totalLength: UInt64? = nil,
        entered: AsyncCompleter<Void>? = nil,
    ) async throws -> (LiveKit.ByteStreamReader, IncomingDataStreamManager) {
        let capture = Capture(entered: entered)
        let manager = IncomingDataStreamManager(delegate: capture, maxPayloadByteLength: nil)
        let streamID = UUID().uuidString

        let header = Livekit_DataStream.Header.with {
            $0.streamID = streamID
            $0.topic = topic
            $0.mimeType = mimeType
            $0.contentHeader = .byteHeader(.with { $0.name = Self.withoutNUL(fileName ?? name) })
            if let totalLength { $0.totalLength = totalLength }
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

    /// Feeds `chunks` to the open stream `streamID`, numbered from zero, then its trailer if asked.
    func feed(_ manager: IncomingDataStreamManager, streamID: String, chunks: [Data], trailer: Bool) {
        for (index, content) in chunks.enumerated() {
            let chunk = Livekit_DataStream.Chunk.with {
                $0.streamID = streamID
                $0.chunkIndex = UInt64(index)
                $0.content = content
            }
            feed(manager) { $0.streamChunk = chunk }
        }
        guard trailer else { return }
        let end = Livekit_DataStream.Trailer.with { $0.streamID = streamID }
        feed(manager) { $0.streamTrailer = end }
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

    func feed(
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
