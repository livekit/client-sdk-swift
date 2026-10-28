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

/// Cancelling a read, a file write or a progress observation. A cancelled read returns at once with
/// `CancellationError` and closes the core reader, which ends the stream. The stand-in core readers
/// report when a read or a progress wait is pending in them, so a cancel can hit one that is really
/// waiting there.
extension ByteStreamReaderTests {
    /// A cancelled read ends the stream, as a v1 reader's cancel did: the read throws
    /// `CancellationError` at once, the stream is no longer open although the sender sent nothing
    /// more, and a later read throws `.alreadyClosed`. The cancel hits a read that waits in the core,
    /// or a task that was cancelled before its read started.
    @Test(arguments: Kind.allCases, CancelledRead.all)
    func cancelledReadEndsTheStream(_ kind: Kind, _ cancelled: CancelledRead) async throws {
        let (capture, manager) = try await openStalledReader(kind)
        let reader = try #require(capture.take())

        let read = Task {
            if !cancelled.whileWaiting { withUnsafeCurrentTask { $0?.cancel() } }
            if cancelled.readAll {
                try await reader.readAll()
            } else {
                try await reader.iterate()
            }
        }
        if cancelled.whileWaiting {
            try await capture.signals.readEntered.wait()
            read.cancel()
        }
        let error = try await within("Cancelled read") { await read.result.failure }
        #expect(error is CancellationError)

        let open = await manager.openStreamCount()
        #expect(open == 0)
        await #expect(throws: StreamError.alreadyClosed) { try await reader.readAll() }
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

    /// Cancelling the observation of a stalled stream's progress does not end the stream, and
    /// releasing the reader afterwards does. The cancel leaves the core's progress wait pending,
    /// which holds the core reader, so only the reader's own release can close it.
    @Test(arguments: Kind.allCases)
    func releasingReaderAfterCancelledProgressEndsTheStream(_ kind: Kind) async throws {
        let (capture, manager) = try await openStalledReader(kind)
        var reader: AnyReader? = capture.take()
        let progress = try #require(reader).progress()

        let observing = Task { for await _ in progress {} }
        try await capture.signals.progressWaiting.wait()
        observing.cancel()
        try await within("Cancelled progress") { await observing.value }
        let openAfterCancel = await manager.openStreamCount()
        #expect(openAfterCancel == 1)

        reader = nil
        let openAfterRelease = await manager.openStreamCount()
        #expect(openAfterRelease == 0)
    }

    /// Progress that is still being observed keeps its reader: after the app releases the reader,
    /// the stream stays open, and the observation follows it to its normal end.
    @Test(arguments: Kind.allCases)
    func observedProgressKeepsTheStreamOpen(_ kind: Kind) async throws {
        let streamID = UUID().uuidString
        let (capture, manager) = try await openStalledReader(kind, streamID: streamID)
        var reader: AnyReader? = capture.take()
        let progress = try #require(reader).progress()

        let firstUpdate = AsyncCompleter<Void>(label: "First progress update", defaultTimeout: 5)
        let received = StateSync<[Int]>([])
        let observing = Task {
            for await update in progress {
                received.mutate { $0.append(update.bytesProcessed) }
                firstUpdate.resume(returning: ())
            }
        }
        try await firstUpdate.wait()
        reader = nil
        let openAfterRelease = await manager.openStreamCount()
        #expect(openAfterRelease == 1)

        feed(manager) {
            $0.streamChunk = Livekit_DataStream.Chunk.with {
                $0.streamID = streamID
                $0.content = Data("abcde".utf8)
            }
        }
        feed(manager) { $0.streamTrailer = Livekit_DataStream.Trailer.with { $0.streamID = streamID } }
        try await within("Progress to the end of the stream") { await observing.value }
        #expect(received.copy().last == 5)
        let openAfterEnd = await manager.openStreamCount()
        #expect(openAfterEnd == 0)
    }

    // MARK: - Helpers

    /// Which public reader a test drives.
    enum Kind: CaseIterable, Sendable {
        case byte, text
    }

    /// How a read meets its cancel: `readAll()` or the iterator, waiting in the core or in a task
    /// cancelled before the read starts.
    struct CancelledRead: Sendable, CustomTestStringConvertible {
        let readAll: Bool
        let whileWaiting: Bool

        static let all = [false, true].flatMap { readAll in [false, true].map { CancelledRead(readAll: readAll, whileWaiting: $0) } }

        var testDescription: String {
            "\(readAll ? "readAll()" : "next()") cancelled \(whileWaiting ? "while waiting" : "before it starts")"
        }
    }

    /// A public reader of either kind, reduced to what the cancellation tests drive. It holds the
    /// reader, so releasing it releases the reader.
    struct AnyReader: Sendable {
        let readAll: @Sendable () async throws -> Void
        let iterate: @Sendable () async throws -> Void
        let progress: @Sendable () -> AsyncStream<LiveKit.StreamProgress>
    }

    /// What a stand-in core reader reports: a read that entered it, and a progress wait pending in
    /// it after the first update.
    struct Signals: Sendable {
        let readEntered = AsyncCompleter<Void>(label: "Read entered the core", defaultTimeout: 5)
        let progressWaiting = AsyncCompleter<Void>(label: "Progress wait pending in the core", defaultTimeout: 5)

        func progressCalled(_ calls: StateSync<Int>) {
            if calls.mutate({ $0 += 1; return $0 }) > 1 { progressWaiting.resume(returning: ()) }
        }
    }

    /// Wraps the core's byte reader to report to ``Signals``.
    final class SignallingByteReader: LiveKitFFI.ByteStreamReaderProtocol {
        private let inner: any LiveKitFFI.ByteStreamReaderProtocol
        private let signals: Signals
        private let progressCalls = StateSync(0)

        init(_ inner: any LiveKitFFI.ByteStreamReaderProtocol, signals: Signals) {
            self.inner = inner
            self.signals = signals
        }

        func info() -> LiveKitFFI.ByteStreamInfo { inner.info() }

        func close() { inner.close() }

        func nextProgress() async -> LiveKitFFI.StreamProgress? {
            signals.progressCalled(progressCalls)
            return await inner.nextProgress()
        }

        func next() async throws -> Data? {
            signals.readEntered.resume(returning: ())
            return try await inner.next()
        }

        func readAll() async throws -> Data {
            signals.readEntered.resume(returning: ())
            return try await inner.readAll()
        }
    }

    /// Wraps the core's text reader to report to ``Signals``.
    final class SignallingTextReader: LiveKitFFI.TextStreamReaderProtocol {
        private let inner: any LiveKitFFI.TextStreamReaderProtocol
        private let signals: Signals
        private let progressCalls = StateSync(0)

        init(_ inner: any LiveKitFFI.TextStreamReaderProtocol, signals: Signals) {
            self.inner = inner
            self.signals = signals
        }

        func info() -> LiveKitFFI.TextStreamInfo { inner.info() }

        func close() { inner.close() }

        func nextProgress() async -> LiveKitFFI.StreamProgress? {
            signals.progressCalled(progressCalls)
            return await inner.nextProgress()
        }

        func next() async throws -> String? {
            signals.readEntered.resume(returning: ())
            return try await inner.next()
        }

        func readAll() async throws -> String {
            signals.readEntered.resume(returning: ())
            return try await inner.readAll()
        }
    }

    /// Builds the public reader around a signalling core reader, and hands it over once, so the
    /// capture keeps no reference to it.
    final class ReaderCapture: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let signals = Signals()
        let opened = AsyncCompleter<Void>(label: "Stream opened", defaultTimeout: 10)
        private let reader = StateSync<AnyReader?>(nil)

        func onByteStreamOpened(reader: LiveKitFFI.ByteStreamReader, identity _: String) {
            let stream = LiveKit.ByteStreamReader(SignallingByteReader(reader, signals: signals))
            hand(AnyReader(readAll: { _ = try await stream.readAll() }, iterate: { for try await _ in stream {} }, progress: { stream.progress }))
        }

        func onTextStreamOpened(reader: LiveKitFFI.TextStreamReader, identity _: String) {
            let stream = LiveKit.TextStreamReader(SignallingTextReader(reader, signals: signals))
            hand(AnyReader(readAll: { _ = try await stream.readAll() }, iterate: { for try await _ in stream {} }, progress: { stream.progress }))
        }

        func onStreamClosed(streamId _: String, identity _: String) {}

        /// Takes the reader, so this capture no longer holds it.
        func take() -> AnyReader? {
            reader.mutate {
                defer { $0 = nil }
                return $0
            }
        }

        private func hand(_ stream: AnyReader) {
            reader.mutate { $0 = stream }
            opened.resume(returning: ())
        }
    }

    /// Opens a stream of `kind` that has only its header, so reads and progress wait in the core.
    /// Returns the capture that holds the reader, and the manager, which the caller must keep alive.
    func openStalledReader(_ kind: Kind, streamID: String = UUID().uuidString) async throws -> (ReaderCapture, IncomingDataStreamManager) {
        let capture = ReaderCapture()
        let manager = IncomingDataStreamManager(delegate: capture, maxPayloadByteLength: nil)
        feed(manager) {
            $0.streamHeader = Livekit_DataStream.Header.with {
                $0.streamID = streamID
                $0.topic = topic
                $0.contentHeader = kind == .byte ? .byteHeader(Livekit_DataStream.ByteHeader()) : .textHeader(Livekit_DataStream.TextHeader())
            }
        }
        try await capture.opened.wait()
        return (capture, manager)
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
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
