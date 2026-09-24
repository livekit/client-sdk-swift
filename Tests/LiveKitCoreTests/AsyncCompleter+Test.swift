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

import Foundation
@testable import LiveKit
import Testing

extension AsyncCompleter {
    /// Yields until at least `count` waiters have parked on this completer — used
    /// when a Task awaits on a completer and the test needs to act only after
    /// the wait has parked.
    ///
    /// Bounded: a waiter that times out or is cancelled leaves, so a count that is never reached
    /// records an issue after `timeout` instead of spinning for the rest of the run.
    func waitForRegistration(count: Int = 1, timeout: TimeInterval = 30, sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = Date().addingTimeInterval(timeout)
        while waiterCount < count {
            guard Date() < deadline else {
                Issue.record("Only \(waiterCount) of \(count) waiter(s) registered within \(timeout)s", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
        }
    }
}
