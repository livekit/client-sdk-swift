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

@propertyWrapper
@dynamicMemberLookup
public final class Atomic<Value> {

    // use concurrent queue to allow multiple reads and block writes with barrier.
    private let queue = DispatchQueue(label: "LiveKitSDK.atomic-wrapper", qos: .default,
                                      attributes: [.concurrent])

    private var value: Value

    public init(wrappedValue value: Value) {
        self.value = value
    }

    public var wrappedValue: Value {
        // concurrent read
        get { queue.sync { value } }
        // blocking
        // queue.sync(flags: .barrier) { value = newValue }
        set { fatalError("use mutate() to mutate this value") }
    }

    public var projectedValue: Atomic<Value> { self }

    public func mutate<Result>(_ mutation: (inout Value) throws -> Result) rethrows -> Result {
        // blocking
        try queue.sync(flags: .barrier) { try mutation(&value) }
    }

    subscript<Property>(dynamicMember keyPath: WritableKeyPath<Value, Property>) -> Property {
        get { queue.sync { value[keyPath: keyPath] } }
        set { queue.sync(flags: .barrier) { value[keyPath: keyPath] = newValue } }
    }

    subscript<Property>(dynamicMember keyPath: KeyPath<Value, Property>) -> Property {
        queue.sync { value[keyPath: keyPath] }
    }
}