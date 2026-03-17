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

struct OrderedSet<Element: Hashable> {
    private var array: [Element] = []
    private var set: [Element: Int] = [:]

    init() {}

    var elements: [Element] { array }

    @discardableResult
    mutating func append(_ element: Element) -> (inserted: Bool, index: Int) {
        if let existing = set[element] {
            return (inserted: false, index: existing)
        }
        let index = array.count
        array.append(element)
        set[element] = index
        return (inserted: true, index: index)
    }
}

extension OrderedSet: Sendable where Element: Sendable {}
