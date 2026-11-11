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

internal import LiveKitFFI
import Foundation

/// The slice of ``TextStreamReader`` the SDK's own consumers (the RPC managers) need. They take
/// this rather than the concrete reader so a stand-in can be built in the test target — otherwise
/// the reader itself has to carry a second, in-memory backing that ships to every app.
protocol TextStreamReading: Sendable {
    var info: TextStreamInfo { get }
    func readAll() async throws -> String
}

/// An asynchronous sequence of chunks read from a text data stream.
///
/// Cancelling a task that reads the stream ends the stream: the read throws `CancellationError`,
/// and a later read throws ``StreamError/alreadyClosed``. Cancellation may discard an in-flight
/// chunk or a partial `readAll()` result. When observed before a read returns, it takes precedence
/// over a concurrent core failure; the stream has finished closing before the error is thrown.
@objcMembers
public final class TextStreamReader: NSObject, AsyncSequence, Sendable, TextStreamReading {
    /// Information about the incoming text stream.
    ///
    /// Once the stream has ended, ``StreamInfo/attributes`` also holds the attributes the sender
    /// set when it closed the stream. They replace header attributes with the same key.
    /// Each access returns a fresh snapshot. A previously cached info object does not change;
    /// read this property again after completion to obtain trailer attributes.
    public var info: TextStreamInfo {
        let info = reader.info()
        return TextStreamInfo(info, encryptionType: EncryptionType(info.encryptionType))
    }

    /// The core's reader, by its protocol so a test can stand in for it.
    private let reader: any LiveKitFFI.TextStreamReaderProtocol
    private let reads = StreamReadSerialiser()
    private let progressRelay: StreamProgressRelay
    private let progressTask = StateSync<AnyTaskCancellable?>(nil)

    init(_ reader: any LiveKitFFI.TextStreamReaderProtocol) {
        self.reader = reader
        progressRelay = StreamProgressRelay { await reader.nextProgress().map(StreamProgress.init) }
    }

    deinit {
        progressTask.copy()?.cancel()
        // The core ends the stream when it releases its reader, which it cannot do while a
        // cancelled `progress` wait still holds it. Closing ends that wait too.
        reader.close()
    }

    /// Reads incoming chunks from the text stream, concatenating them into a single string which is returned
    /// once the stream closes normally. Concurrent chunk reads wait until this operation completes.
    ///
    /// - Returns: The string consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream, or
    ///   `CancellationError` after closing the stream if the calling task is cancelled,
    ///   so a later read throws ``StreamError/alreadyClosed``.
    ///
    public func readAll() async throws -> String {
        try await StreamError.reading(closingOnCancel: reader.close) {
            try await reads.run { [reader] in
                var result = ""
                while let chunk = try await reader.next() {
                    try Task.checkCancellation()
                    result.append(chunk)
                }
                return result
            }
        }
    }

    /// The progress of the stream as its bytes arrive, until the stream ends.
    ///
    /// Progress counts the bytes received from the sender, after decompression, not the bytes read
    /// so far. ``StreamProgress/bytesTotal`` is the size the sender declared, or `nil` if it
    /// declared none. Updates that arrive between two iterations merge into the latest one, and the
    /// last update is the stream's final progress. Iterate it from one task at a time.
    ///
    /// The sequence keeps the reader, and so the stream, alive until it finishes or its iteration
    /// is cancelled, also after you release the reader. Cancelling the iteration does not end the
    /// stream. A replacement observation receives the latest progress, including the final update
    /// after completion. Cancellation detaches only the observation from the shared native wait.
    ///
    /// ```swift
    /// Task {
    ///     for await progress in reader.progress {
    ///         print("Received \(progress.bytesProcessed) bytes")
    ///     }
    /// }
    /// let text = try await reader.readAll()
    /// ```
    public var progress: AsyncStream<StreamProgress> {
        let version = StateSync(0)
        return AsyncStream(unfolding: { [self] in
            guard let update = try? await progressRelay.next(after: version.copy()) else { return nil }
            version.mutate { $0 = update.version }
            return update.progress
        })
    }

    /// An asynchronous iterator of incoming chunks.
    public struct AsyncChunks: AsyncIteratorProtocol {
        fileprivate let stream: TextStreamReader

        public mutating func next() async throws -> String? {
            try await stream.nextChunk()
        }
    }

    public func makeAsyncIterator() -> AsyncChunks {
        AsyncChunks(stream: self)
    }

    private func nextChunk() async throws -> String? {
        try await StreamError.reading(closingOnCancel: reader.close) {
            try await reads.run { [reader] in try await reader.next() }
        }
    }
}

// MARK: - Objective-C compatibility

@available(*, deprecated, message: "Use for/await on TextStreamReader reader instead.")
public extension TextStreamReader {
    @objc
    func readChunks(onChunk: @Sendable @escaping (String) -> Void, onCompletion: (@Sendable (Error?) -> Void)?) {
        Task {
            do {
                for try await chunk in self {
                    onChunk(chunk)
                }
                onCompletion?(nil)
            } catch {
                onCompletion?(error)
            }
        }
    }
}

public extension TextStreamReader {
    /// Calls `onProgress` with each update of ``progress``, for Objective-C callers.
    ///
    /// The observation ends when the stream ends, the reader is released, or
    /// ``stopReadingProgress()`` is called. Calling this again replaces the previous observation.
    /// Keep the reader alive while observing; the callback should not retain it.
    @objc
    @available(swift, deprecated: 1, message: "Use for/await on TextStreamReader progress instead.")
    func readProgress(onProgress: @Sendable @escaping (StreamProgress) -> Void) {
        let previous = progressTask.mutate { current in
            let previous = current
            current = Task { [progressRelay] in
                var version = 0
                while let update = try? await progressRelay.next(after: version) {
                    guard !Task.isCancelled else { return }
                    version = update.version
                    onProgress(update.progress)
                }
            }.cancellable()
            return previous
        }
        previous?.cancel()
    }

    /// Cancels the observation started by ``readProgress(onProgress:)`` without closing the stream.
    ///
    /// The callback and observation are released even if the core's progress wait is still pending.
    /// A callback already in flight may finish. A replacement observation replays the latest
    /// update. Releasing the reader closes the stream and pending native wait.
    /// Ordinary Swift ``progress`` iteration is unaffected.
    @objc
    func stopReadingProgress() {
        let previous = progressTask.mutate { current in
            defer { current = nil }
            return current
        }
        previous?.cancel()
    }
}
