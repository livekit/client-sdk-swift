/*
 * Copyright 2025 LiveKit
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


/// An asynchronous sequence of chunks read from a text data stream.
@objc
public final class TextStreamReader: NSObject, AsyncSequence, Sendable {

    /// Information about the incoming text stream.
    @objc
    public let info: TextStreamInfo
    
    let source: StreamReader<String>

    init(info: TextStreamInfo, source: StreamReaderSource) {
        self.info = info
        self.source = StreamReader(source: source)
    }
    
    public func makeAsyncIterator() -> StreamReader<String>.Iterator {
        source.makeAsyncIterator()
    }
    
    /// Reads incoming chunks from the text stream, concatenating them into a single string which is returned
    /// once the stream closes normally.
    ///
    /// - Returns: The string consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream.
    ///
    public func readAll() async throws -> String {
        try await source.readAll()
    }
}

// MARK: - Objective-C compatibility

extension TextStreamReader {
    @objc
    @available(*, unavailable, message: "Use async readAll() method instead.")
    public func readAll(onCompletion: (@escaping (String) -> Void), onError: ((Error?) -> ())?) {
        source.readAll(onCompletion: onCompletion, onError: onError)
    }
    
    @objc
    @available(*, unavailable, message: "Use for/await on TextStreamReader reader instead.")
    public func readChunks(onChunk: (@escaping (String) -> Void), onCompletion: ((Error?) -> Void)?) {
        source.readChunks(onChunk: onChunk, onCompletion: onCompletion)
    }
}
