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

internal class Completer<Value: Equatable> {

    private var promise = Promise<Value>.pending()
    private var oldValue: Value?

    public func set(value: Value?) {

        guard oldValue != value else {
            // value did not update
            return
        }

        // reset if nil
        guard let value = value else {
            reset()
            return
        }

        // update the oldValue
        oldValue = value
        promise.fulfill(value)
    }

    public func wait(on queue: DispatchQueue, _ interval: TimeInterval) -> Promise<Value> {
        promise.timeout(on: queue, interval)
    }

    public func reset() {
        // reject existing promise
        promise.reject(InternalError.state(message: "resetting pending promise"))
        // create new pending promise
        promise = Promise<Value>.pending()
        // reset oldValue
        oldValue = nil
    }
}
