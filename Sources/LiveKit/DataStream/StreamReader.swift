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

protocol StreamReader: AsyncSequence {

    typealias Source = AsyncThrowingStream<Data, any Error>
    associatedtype Info: StreamInfo
    
    func readAll() async throws -> Element
    func readChunks(onChunk: (@escaping (Element) -> Void), onCompletion: ((Error?) -> Void)?)
    
    init(info: Info, source: Source)
}

// MARK: - Default implementations

extension StreamReader where Element: RangeReplaceableCollection {
    func readAll() async throws -> Element {
        try await reduce(Element()) { $0 + $1 }
    }
}

extension StreamReader {
    func readChunks(onChunk: (@escaping (Element) -> Void), onCompletion: ((Error?) -> Void)? = nil) {
        Task {
            do {
                for try await chunk in self { onChunk(chunk) }
                onCompletion?(nil)
            } catch {
                onCompletion?(error)
            }
        }
    }
}
