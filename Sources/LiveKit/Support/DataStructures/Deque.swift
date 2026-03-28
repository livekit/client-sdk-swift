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

// API inspired by swift-collections by Apple Inc.
// https://github.com/apple/swift-collections

/// A double-ended queue backed by a circular buffer.
/// Provides O(1) amortized `append` and `removeFirst`.
struct Deque<Element>: ExpressibleByArrayLiteral {
    private var buffer: [Element?] = []
    private var head = 0
    private var count_ = 0

    init() {}

    init(arrayLiteral elements: Element...) {
        buffer = elements.map { $0 }
        count_ = elements.count
    }

    var isEmpty: Bool { count_ == 0 }

    var first: Element? {
        guard count_ > 0 else { return nil }
        return buffer[head]
    }

    mutating func append(_ element: Element) {
        if count_ == buffer.count {
            grow()
        }
        let tail = (head + count_) & (buffer.count - 1)
        buffer[tail] = element
        count_ += 1
    }

    @discardableResult
    mutating func removeFirst() -> Element {
        guard count_ > 0 else {
            preconditionFailure("Cannot removeFirst from an empty Deque")
        }
        let element = buffer[head]!
        buffer[head] = nil
        head = (head + 1) & (buffer.count - 1)
        count_ -= 1
        return element
    }

    private mutating func grow() {
        let newCapacity = max(buffer.count * 2, 4)
        var newBuffer = [Element?](repeating: nil, count: newCapacity)
        let mask = buffer.count - 1
        for i in 0 ..< count_ {
            newBuffer[i] = buffer[(head + i) & mask]
        }
        buffer = newBuffer
        head = 0
    }
}

extension Deque: Sendable where Element: Sendable {}
