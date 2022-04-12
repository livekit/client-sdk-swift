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
public class Atomic<Value> {

    private let queue = DispatchQueue(label: "LiveKitSDK.atomic-wrapper", qos: .default)
    private var value: Value

    public init(wrappedValue: Value) {
        self.value = wrappedValue
    }

    public var projectedValue: Atomic<Value> {
        return self
    }

    public var wrappedValue: Value {
        get { queue.sync { value } }
        set { queue.sync { value = newValue } }
    }

    public func mutate<Result>(_ mutation: (inout Value) -> Result) -> Result {
        queue.sync { mutation(&value) }
    }
}
