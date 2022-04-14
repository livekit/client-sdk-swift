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

extension Sequence where Element == Promise<Void> {

    func all(on queue: DispatchQueue = .promises) -> Promise<Void> {
        Promises.all(on: queue, self).then(on: queue) { _ in }
    }
}

internal extension Promise {

    typealias OnTimeout = () -> Error

    func timeout(on queue: DispatchQueue = .promises, _ interval: TimeInterval, `throw` _throw: @escaping OnTimeout) -> Promise {

        self.timeout(on: queue, interval).recover(on: queue) { error -> Promise in
            // if this is a timedOut error...
            if let error = error as? PromiseError, case .timedOut = error {
                throw _throw()
            }
            // re-throw
            throw error
        }
    }
}
