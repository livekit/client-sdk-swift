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

/// Cancelling a read or a file write: the call returns at once, the stream stays readable, and the
/// declared length still holds. The reader under test reports when a read enters the core, so each
/// cancel hits a read that is really waiting there.
extension ByteStreamReaderTests {
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
        let entered = AsyncCompleter<Void>(label: "Read entered the core", defaultTimeout: 5)
        let (reader, manager) = try await openReader(chunks: [], trailerReason: nil, entered: entered)

        let read = Task { try await reader.readAll() }
        try await entered.wait()
        read.cancel()
        let error = try await within("Cancelled readAll") { await read.result.failure }
        #expect(error is CancellationError)

        let chunk = Data(repeating: 0x7F, count: 64)
        feed(manager, streamID: reader.info.id, chunks: [chunk, chunk, chunk], trailer: true)

        let rest = try await within("The rest of the stream") { try await Self.readByIterating(reader) }
        #expect(rest.count >= 2 * chunk.count)
    }

    /// A chunk that a cancelled read took still counts toward the length the header declared, so
    /// the stream completes when a later read reaches its end.
    @Test func cancelledReadKeepsLengthCount() async throws {
        let entered = AsyncCompleter<Void>(label: "Read entered the core", defaultTimeout: 5)
        let (reader, manager) = try await openReader(chunks: [], trailerReason: nil, totalLength: 8, entered: entered)

        let read = Task {
            var chunks = reader.makeAsyncIterator()
            return try await chunks.next()
        }
        try await entered.wait()
        read.cancel()
        let error = try await within("Cancelled next") { await read.result.failure }
        #expect(error is CancellationError)

        feed(manager, streamID: reader.info.id, chunks: [Data("abcd".utf8), Data("efgh".utf8)], trailer: true)

        let rest = try await within("The rest of the stream") { try await reader.readAll() }
        #expect(rest.count == 4)
    }

    /// A read cancelled while it waits in the core leaves no stream open once the stream ends.
    @Test func cancelledReadLeavesNoOpenStream() async throws {
        let entered = AsyncCompleter<Void>(label: "Read entered the core", defaultTimeout: 5)
        let (reader, manager) = try await openReader(chunks: [], trailerReason: nil, totalLength: 4, entered: entered)

        let read = Task { try await reader.readAll() }
        try await entered.wait()
        read.cancel()
        let error = try await within("Cancelled readAll") { await read.result.failure }
        #expect(error is CancellationError)

        feed(manager, streamID: reader.info.id, chunks: [Data("abcd".utf8)], trailer: true)
        // The core answers the count in order with the packets fed before it.
        let open = try await within("Open stream count") { await manager.openStreamCount() }
        #expect(open == 0)
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

    // MARK: - Helpers

    /// Wraps a core reader and reports when a read enters it, so a test can cancel a read that is
    /// really waiting in the core.
    final class SignallingReader: LiveKitFFI.ByteStreamReaderProtocol {
        private let inner: any LiveKitFFI.ByteStreamReaderProtocol
        private let entered: AsyncCompleter<Void>

        init(_ inner: any LiveKitFFI.ByteStreamReaderProtocol, entered: AsyncCompleter<Void>) {
            self.inner = inner
            self.entered = entered
        }

        func info() -> LiveKitFFI.ByteStreamInfo {
            inner.info()
        }

        func next() async throws -> Data? {
            entered.resume(returning: ())
            return try await inner.next()
        }

        func readAll() async throws -> Data {
            entered.resume(returning: ())
            return try await inner.readAll()
        }
    }

    /// Runs `body` in its own task and waits at most 5 s for it, however `body` treats cancellation.
    private func within<T: Sendable>(_ label: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let result = AsyncCompleter<T>(label: label, defaultTimeout: 5)
        Task {
            do {
                try await result.resume(returning: body())
            } catch {
                result.resume(throwing: error)
            }
        }
        return try await result.wait()
    }

    private static func readByIterating(_ reader: LiveKit.ByteStreamReader) async throws -> Data {
        var data = Data()
        for try await chunk in reader {
            data += chunk
        }
        return data
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
