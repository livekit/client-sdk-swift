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
// Licensed under Apache License 2.0 with Runtime Library Exception.

struct OrderedDictionary<Key: Hashable, Value>: ExpressibleByDictionaryLiteral {
    private var pairs: [(key: Key, value: Value)] = []
    private var index: [Key: Int] = [:]

    init() {}

    init(dictionaryLiteral elements: (Key, Value)...) {
        for (key, value) in elements {
            pairs.append((key, value))
            index[key] = pairs.count - 1
        }
    }

    init(uniqueKeysWithValues keysAndValues: some Sequence<(Key, Value)>) {
        for (key, value) in keysAndValues {
            pairs.append((key, value))
            index[key] = pairs.count - 1
        }
    }

    var count: Int { pairs.count }

    var keys: Keys { Keys(pairs: pairs) }
    var values: Values { Values(pairs: pairs) }

    subscript(key: Key) -> Value? {
        get {
            guard let i = index[key] else { return nil }
            return pairs[i].value
        }
        set {
            if let newValue {
                if let i = index[key] {
                    pairs[i] = (key, newValue)
                } else {
                    index[key] = pairs.count
                    pairs.append((key, newValue))
                }
            } else if let i = index.removeValue(forKey: key) {
                pairs.remove(at: i)
                for j in i ..< pairs.count {
                    index[pairs[j].key] = j
                }
            }
        }
    }

    @discardableResult
    mutating func updateValue(_ value: Value, forKey key: Key) -> Value? {
        if let i = index[key] {
            let old = pairs[i].value
            pairs[i] = (key, value)
            return old
        }
        index[key] = pairs.count
        pairs.append((key, value))
        return nil
    }

    struct Keys {
        fileprivate let pairs: [(key: Key, value: Value)]
        subscript(position: Int) -> Key { pairs[position].key }
    }

    struct Values {
        fileprivate let pairs: [(key: Key, value: Value)]
        var elements: [Value] { pairs.map(\.value) }
        subscript(position: Int) -> Value { pairs[position].value }
    }
}

extension OrderedDictionary: Sendable where Key: Sendable, Value: Sendable {}
extension OrderedDictionary.Keys: Sendable where Key: Sendable, Value: Sendable {}
extension OrderedDictionary.Values: Sendable where Key: Sendable, Value: Sendable {}
