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
import Promises

internal struct Completer<Value>: Loggable {

    private var value: Value?
    private var fulfill: ((Value) -> Void)?
    private var reject: ((Error) -> Void)?

    public mutating func set(value newValue: Value?) {

        guard let newValue = newValue else {
            // reset if oldValue exists and newValue is nil
            if value != nil { reset() }
            return
        }

        log("[publish] fulfill \(String(describing: newValue)) func: \(String(describing: fulfill))...")

        // update the oldValue
        value = newValue

        fulfill?(newValue)
        fulfill = nil
        reject = nil
    }

    public mutating func wait(on queue: DispatchQueue, _ interval: TimeInterval, throw: @escaping Promise.OnTimeout) -> Promise<Value> {
        log("[publish] wait created...")

        if let value = value {
            // already resolved
            return Promise(value)
        }

        let promise = Promise<Value>.pending()
        self.fulfill = promise.fulfill(_:)
        self.reject = promise.reject(_:)
        return promise.timeout(on: queue, interval, throw: `throw`)
    }

    public mutating func reset() {
        // reject existing promise
        reject?(InternalError.state(message: "resetting pending promise"))

        fulfill = nil
        reject = nil
        value = nil
    }
}
