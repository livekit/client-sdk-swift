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

internal class Completer<Value> {

    internal struct State {
        var oldValue: Value?
        // not a struct but keeping it here will ensure safe access by mutate()
        let promise = Promise<Value>.pending()
    }

    private var state = StateSync(State())

    public func set(value: Value?) {

        guard let value = value else {

            // reset if oldValue exists and newValue is nil
            if state.oldValue != nil {
                reset()
            }

            return
        }

        // update the oldValue
        state.mutate {
            $0.oldValue = value
            $0.promise.fulfill(value)
        }
    }

    public func wait(on queue: DispatchQueue, _ interval: TimeInterval, throw: @escaping Promise.OnTimeout) -> Promise<Value> {
        state.promise.timeout(on: queue, interval, throw: `throw`)
    }

    public func reset() {

        state.mutate {
            // reject existing promise
            $0.promise.reject(InternalError.state(message: "resetting pending promise"))
            // reset state
            $0 = State()
        }
    }
}
