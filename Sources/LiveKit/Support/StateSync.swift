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

    // use concurrent queue to allow multiple reads and block writes with barrier.
    private let queue = DispatchQueue(label: "LiveKitSDK.state", qos: .default,
                                      attributes: [.concurrent])

    // actual value
    private var _value: Value
    public var onMutate: OnStateMutate<Value>?

    public init(_ value: Value, onMutate: OnStateMutate<Value>? = nil) {
        self._value = value
        self.onMutate = onMutate
    }

    // mutate
    @discardableResult
    public func mutate<Result>(_ mutation: (inout Value) throws -> Result) rethrows -> Result {
        // blocking
        try queue.sync(flags: .barrier) {
            let oldValue = _value
            let result = try mutation(&_value)
            onMutate?(_value, oldValue)
            return result
        }
    }

    public func mutateAsync(_ mutation: @escaping (inout Value) -> Void) {
        // blocking
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let oldValue = self._value
            mutation(&self._value)
            self.onMutate?(self._value, oldValue)
        }
    }

    // read only
    subscript<Property>(dynamicMember keyPath: KeyPath<Value, Property>) -> Property {
        queue.sync { _value[keyPath: keyPath] }
    }
}

extension StateSync: CustomStringConvertible {

    var description: String {
        "StateSync(\(String(describing: _value)))"
    }
}
