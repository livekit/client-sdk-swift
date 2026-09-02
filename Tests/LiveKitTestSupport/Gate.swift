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

/// A signal that cannot be missed: `open()` may run before or after any number of `wait()` calls,
/// and every waiter returns once it is open. Lets a test hold one step of the code under test
/// until the test has acted. A waiter gives up after `timeout` so a broken build fails instead of
/// hanging.
public final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let _state = StateSync(State())

    public init() {}

    public func open() {
        let waiters: [CheckedContinuation<Void, Never>] = _state.mutate { state in
            state.isOpen = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func wait(timeout: TimeInterval = 10) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            let isOpen: Bool = _state.mutate { state in
                if state.isOpen { return true }
                state.waiters[id] = continuation
                return false
            }
            if isOpen {
                continuation.resume()
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                let timedOut: CheckedContinuation<Void, Never>? = _state.mutate { state in
                    state.waiters.removeValue(forKey: id)
                }
                timedOut?.resume()
            }
        }
    }
}
