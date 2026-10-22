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

internal import LiveKitFFI

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
/// and a later read throws ``StreamError/alreadyClosed``.
@objcMembers
public final class TextStreamReader: NSObject, AsyncSequence, Sendable, TextStreamReading {
    /// Information about the incoming text stream.
    ///
    /// Once the stream has ended, ``StreamInfo/attributes`` also holds the attributes the sender
    /// set when it closed the stream. They replace header attributes with the same key.
    public var info: TextStreamInfo {
        let info = reader.info()
        return TextStreamInfo(info, encryptionType: EncryptionType(info.encryptionType))
    }

    /// The core's reader, by its protocol so a test can stand in for it.
    private let reader: any LiveKitFFI.TextStreamReaderProtocol

    init(_ reader: any LiveKitFFI.TextStreamReaderProtocol) {
        self.reader = reader
    }

    /// Reads incoming chunks from the text stream, concatenating them into a single string which is returned
    /// once the stream closes normally.
    ///
    /// - Returns: The string consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream, or
    ///   `CancellationError` at once if the calling task is cancelled. The cancel ends the stream,
    ///   so a later read throws ``StreamError/alreadyClosed``.
    ///
    public func readAll() async throws -> String {
        try await StreamError.reading(closingOnCancel: reader.close) { try await reader.readAll() }
    }

    /// The progress of the stream as its bytes arrive, until the stream ends.
    ///
    /// Progress counts the bytes received from the sender, after decompression, not the bytes read
    /// so far. ``StreamProgress/bytesTotal`` is the size the sender declared, or `nil` if it
    /// declared none. Updates that arrive between two iterations merge into the latest one, and the
    /// last update is the stream's final progress. Iterate it from one task at a time.
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
        // ponytail: a cancel abandons the core's wait, which keeps the reader's progress until its
        // next update or the end of the stream, so an iteration started after it waits for that.
        AsyncStream(unfolding: { [reader] in
            try? await abandoningOnCancel { await reader.nextProgress().map(StreamProgress.init) }
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
        try await StreamError.reading(closingOnCancel: reader.close) { try await reader.next() }
    }
}

// MARK: - Objective-C compatibility

public extension TextStreamReader {
    @objc
    @available(*, deprecated, message: "Use for/await on TextStreamReader reader instead.")
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

    @objc
    @available(*, deprecated, message: "Use for/await on TextStreamReader progress instead.")
    func readProgress(onProgress: @Sendable @escaping (StreamProgress) -> Void) {
        Task {
            for await progress in self.progress {
                onProgress(progress)
            }
        }
    }
}
