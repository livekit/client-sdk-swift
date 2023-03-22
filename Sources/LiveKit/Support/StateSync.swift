/*
 * Copyright 2022 LiveKit
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

internal typealias OnStateMutate<Value> = (_ state: Value, _ oldState: Value) -> Void

@dynamicMemberLookup
internal final class StateSync<Value> {

    private let lock = UnfairLock()

    // actual value
    private var _value: Value
    public var onMutate: OnStateMutate<Value>?

    public init(_ value: Value, onMutate: OnStateMutate<Value>? = nil) {
        self._value = value
        self.onMutate = onMutate
    }

    // mutate sync
    @discardableResult
    public func mutate<Result>(_ block: (inout Value) throws -> Result) rethrows -> Result {
        try lock.sync {
            let oldValue = _value
            let result = try block(&_value)
            onMutate?(_value, oldValue)
            return result
        }
    }

    // read sync
    public func readCopy() -> Value {
        lock.sync { _value }
    }

    // read sync
    public func read<Result>(_ block: (Value) throws -> Result) rethrows -> Result {
        try lock.sync {
            try block(_value)
        }
    }

    // property read sync
    subscript<Property>(dynamicMember keyPath: KeyPath<Value, Property>) -> Property {
        lock.sync { _value[keyPath: keyPath] }
    }
}

extension StateSync: CustomStringConvertible {

    var description: String {
        "StateSync(\(String(describing: _value)))"
    }
}
