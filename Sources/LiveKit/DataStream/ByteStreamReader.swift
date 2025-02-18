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

@objc
public final class ByteStreamReader: NSObject, StreamReader, Sendable {
    
    public struct AsyncChunks {
        fileprivate var upstream: AsyncThrowingStream<Data, any Error>.Iterator
    }
    
    private let source: AsyncThrowingStream<Data, any Error>
    
    @objc
    public let info: ByteStreamInfo
    
    init(info: ByteStreamInfo, source: AsyncThrowingStream<Data, any Error>) {
        self.source = source
        self.info = info
    }
    
    @objc
    public func readChunks(_ chuckHandler: (@escaping (Data) -> Void)) {
        fatalError("Not implemented")
    }
    
    @objc
    public func readAll() async throws -> Data {
        fatalError("Not implemented")
    }
}

extension ByteStreamReader {
    @objc
    public func readToFile(in directory: URL? = nil) async throws -> URL {
        fatalError("Not implemented")
    }
}

extension ByteStreamReader: AsyncSequence {
    public func makeAsyncIterator() -> AsyncChunks {
        AsyncChunks(upstream: source.makeAsyncIterator())
    }
}

extension ByteStreamReader.AsyncChunks: AsyncIteratorProtocol {
    mutating public func next() async throws -> Data? {
        try await upstream.next()
    }
}
