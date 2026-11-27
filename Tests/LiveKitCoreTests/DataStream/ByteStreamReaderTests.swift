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

/// Exercises every ``ByteStreamReader`` interface (iterating, `readAll()`, `writeToFile()`) over an
/// in-memory core reader that replays chunks and an end reason.
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
        await #expect {
            try await reader.writeToFile(in: directory)
        } throws: { Self.isIOError($0) }
        #expect(try Data(contentsOf: victim) == Data("original".utf8))
        _ = manager
    }

    /// `notDirectory` only checks the URL's shape, so a directory that does not exist reaches
    /// `open` and fails there. That must still surface as `StreamError`, not as the internal
    /// `AsyncFileStream.Error` the caller cannot name.
    @Test func writeToFileReportsAMissingDirectoryAsStreamError() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)

        let (reader, manager) = try await openReader()
        await #expect {
            try await reader.writeToFile(in: missing)
        } throws: { Self.isIOError($0) }
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
        await #expect {
            try await reader.writeToFile(in: directory)
        } throws: { Self.isIOError($0) }
        #expect(try Data(contentsOf: target) == Data("original".utf8))
        _ = manager
    }

    /// Whether `error` is ``StreamError/io(reason:)``.
    ///
    /// Matches the case, not a whole value: `io` carries the `open` failure's description, and
    /// pinning that text would couple these tests to the message.
    private static func isIOError(_ error: any Error) -> Bool {
        if case .io = error as? StreamError { return true }
        return false
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

    /// Opens a public reader over an in-memory core reader. The second value keeps the core alive,
    /// as the removed manager was kept alive. A `nil` reason leaves the stream open.
    func openReader(
        fileName: String? = nil,
        chunks: [Data]? = nil,
        trailerReason: String? = "",
    ) async throws -> (LiveKit.ByteStreamReader, FakeByteReader) {
        let info = LiveKitFFI.ByteStreamInfo(id: UUID().uuidString, topic: topic, timestampMs: 0, totalLength: nil,
                                             attributes: [:], mimeType: mimeType, name: fileName ?? name, encryptionType: .none)
        let core = FakeByteReader(info: info, chunks: chunks ?? testChunks, endReason: trailerReason)
        return (LiveKit.ByteStreamReader(core), core)
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
}
