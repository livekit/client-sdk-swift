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

extension AsyncSequence {
    func tryMap<T>(
        _ transform: @escaping (Element) async throws -> T
    ) -> AsyncTryMapSequence<Self, T> {
        AsyncTryMapSequence(base: self, transform: transform)
    }
}

struct AsyncTryMapSequence<Base: AsyncSequence, Element>: AsyncSequence {
    fileprivate let base: Base
    fileprivate let transform: (Base.Element) async throws -> Element

    struct Iterator: AsyncIteratorProtocol {
        var baseIterator: Base.AsyncIterator
        let transform: (Base.Element) async throws -> Element

        mutating func next() async throws -> Element? {
            guard let nextElement = try await baseIterator.next() else {
                return nil
            }
            return try await transform(nextElement)
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(baseIterator: base.makeAsyncIterator(), transform: transform)
    }
}
