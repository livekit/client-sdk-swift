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
import Combine

@dynamicMemberLookup
internal final class StateSync<Value: Equatable> {

    typealias OnDidMutate<Value> = (_ newState: Value, _ oldState: Value) -> Void

    private let subject: CurrentValueSubject<Value, Never>
    private let lock = UnfairLock()

    public var onDidMutate: OnDidMutate<Value>?

    public var valuePublisher: AnyPublisher<Value, Never> {
        subject.eraseToAnyPublisher()
    }

    public init(_ value: Value, onMutate: OnDidMutate<Value>? = nil) {
        self.subject = CurrentValueSubject(value)
        self.onDidMutate = onMutate
    }

    // mutate sync
    @discardableResult
    public func mutate<Result>(_ block: (inout Value) throws -> Result) rethrows -> Result {
        try lock.sync {
            let oldValue = subject.value
            var valueCopy = oldValue
            let result = try block(&valueCopy)
            subject.send(valueCopy)
            // trigger onMutate if mutaed value isn't equal any more (Equatable protocol)
            if oldValue != valueCopy {
                onDidMutate?(valueCopy, oldValue)
            }
            return result
        }
    }

    // read sync and return copy
    public func copy() -> Value {
        lock.sync { subject.value }
    }

    // read with block
    public func read<Result>(_ block: (Value) throws -> Result) rethrows -> Result {
        try lock.sync { try block(subject.value) }
    }

    // property read sync
    subscript<Property>(dynamicMember keyPath: KeyPath<Value, Property>) -> Property {
        lock.sync { subject.value[keyPath: keyPath] }
    }
}

extension StateSync: CustomStringConvertible {

    var description: String {
        "StateSync(\(String(describing: copy()))"
    }
}
