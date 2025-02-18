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
public final class TextStreamReader: NSObject, StreamReader, Sendable {

    public struct AsyncChunks {
        fileprivate var upstream: Source.Iterator
    }

    private let source: Source

    @objc
    public let info: TextStreamInfo

    init(info: TextStreamInfo, source: Source) {
        self.source = source
        self.info = info
    }
}

extension TextStreamReader: AsyncSequence {
    public func makeAsyncIterator() -> AsyncChunks {
        AsyncChunks(upstream: source.makeAsyncIterator())
    }
}

extension TextStreamReader.AsyncChunks: AsyncIteratorProtocol {
    mutating public func next() async throws -> String? {
        guard let data = try await upstream.next() else { return nil }
        guard let string = String(data: data, encoding: .utf8) else {
            throw StreamError.invalidString
        }
        return string
    }
}
