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

/// An asynchronous sequence of chunks read from a text data stream.
@objcMembers
public final class TextStreamReader: NSObject, AsyncSequence, Sendable {
    /// Information about the incoming text stream.
    public let info: TextStreamInfo

    // A reader is backed either by the UniFFI core (production) or an in-memory source (internal
    // producers/tests that inject content directly). The FFI path stays pull-based for backpressure.
    private enum Backing: Sendable {
        case ffi(LiveKitUniFFI.TextStreamReader)
        case source(StreamReaderSource)
    }

    private let backing: Backing

    init(_ reader: LiveKitUniFFI.TextStreamReader, info: TextStreamInfo) {
        backing = .ffi(reader)
        self.info = info
    }

    init(info: TextStreamInfo, source: StreamReaderSource) {
        backing = .source(source)
        self.info = info
    }

    /// Reads incoming chunks from the text stream, concatenating them into a single string which is returned
    /// once the stream closes normally.
    ///
    /// - Returns: The string consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream.
    ///
    public func readAll() async throws -> String {
        switch backing {
        case let .ffi(reader):
            do {
                return try await reader.readAll()
            } catch let error as LiveKitUniFFI.DataStreamError {
                throw StreamError(error)
            }
        case let .source(source):
            var result = ""
            for try await chunk in source {
                guard let string = String(data: chunk, encoding: .utf8) else {
                    throw StreamError.decodeFailed
                }
                result += string
            }
            return result
        }
    }

    /// An asynchronous iterator of incoming chunks.
    public struct AsyncChunks: AsyncIteratorProtocol {
        enum Backing {
            case ffi(LiveKitUniFFI.TextStreamReader)
            case source(StreamReaderSource.Iterator)
        }

        var backing: Backing

        public mutating func next() async throws -> String? {
            switch backing {
            case let .ffi(reader):
                do {
                    return try await reader.next()
                } catch let error as LiveKitUniFFI.DataStreamError {
                    throw StreamError(error)
                }
            case var .source(iterator):
                let data = try await iterator.next()
                backing = .source(iterator)
                guard let data else { return nil }
                guard let string = String(data: data, encoding: .utf8) else {
                    throw StreamError.decodeFailed
                }
                return string
            }
        }
    }

    public func makeAsyncIterator() -> AsyncChunks {
        switch backing {
        case let .ffi(reader): AsyncChunks(backing: .ffi(reader))
        case let .source(source): AsyncChunks(backing: .source(source.makeAsyncIterator()))
        }
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
