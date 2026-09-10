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

internal import LiveKitUniFFI

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

    private let reader: LiveKitUniFFI.TextStreamReader

    init(_ reader: LiveKitUniFFI.TextStreamReader, info: TextStreamInfo) {
        self.reader = reader
        self.info = info
    }

    /// Reads incoming chunks from the text stream, concatenating them into a single string which is returned
    /// once the stream closes normally.
    ///
    /// - Returns: The string consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream.
    ///
    public func readAll() async throws -> String {
        do {
            return try await reader.readAll()
        } catch let error as LiveKitUniFFI.DataStreamError {
            throw StreamError(error)
        }
    }

    /// An asynchronous iterator of incoming chunks.
    public struct AsyncChunks: AsyncIteratorProtocol {
        fileprivate let reader: LiveKitUniFFI.TextStreamReader

        public mutating func next() async throws -> String? {
            do {
                return try await reader.next()
            } catch let error as LiveKitUniFFI.DataStreamError {
                throw StreamError(error)
            }
        }
    }

    public func makeAsyncIterator() -> AsyncChunks {
        AsyncChunks(reader: reader)
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
