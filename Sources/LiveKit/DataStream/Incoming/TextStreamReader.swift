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
@objcMembers
public final class TextStreamReader: NSObject, AsyncSequence, Sendable, TextStreamReading {
    /// Information about the incoming text stream.
    public let info: TextStreamInfo

    /// The core's reader, by its protocol so a test can stand in for it.
    private let reader: any LiveKitFFI.TextStreamReaderProtocol

    init(_ reader: any LiveKitFFI.TextStreamReaderProtocol, info: TextStreamInfo) {
        self.reader = reader
        self.info = info
    }

    /// Reads incoming chunks from the text stream, concatenating them into a single string which is returned
    /// once the stream closes normally.
    ///
    /// - Returns: The string consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream, or
    ///   `CancellationError` at once if the calling task is cancelled. The chunk in flight at the
    ///   cancel is dropped, so a later read of the stream misses it.
    ///
    public func readAll() async throws -> String {
        // ponytail: chunk by chunk, so a cancel stops the collection after at most one chunk, but
        // the core keeps buffering the rest of the stream until it ends. Releasing it early needs
        // a per-reader close in the FFI.
        var result = ""
        for try await chunk in self {
            result.append(chunk)
        }
        return result
    }

    /// An asynchronous iterator of incoming chunks.
    public struct AsyncChunks: AsyncIteratorProtocol {
        fileprivate let reader: any LiveKitFFI.TextStreamReaderProtocol
        fileprivate var declaredLength: Int?
        fileprivate var receivedLength = 0

        public mutating func next() async throws -> String? {
            let chunk: String?
            do {
                chunk = try await abandoningOnCancel { [reader] in try await reader.next() }
            } catch let error as LiveKitFFI.DataStreamError {
                throw StreamError(error)
            }
            guard let chunk else {
                // Checked once, so a call after the end returns `nil`.
                defer { declaredLength = nil }
                if let error = StreamError(receivedLength: receivedLength, declaredLength: declaredLength) { throw error }
                return nil
            }
            receivedLength += chunk.utf8.count
            return chunk
        }
    }

    public func makeAsyncIterator() -> AsyncChunks {
        AsyncChunks(reader: reader, declaredLength: info.totalLength)
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
}
