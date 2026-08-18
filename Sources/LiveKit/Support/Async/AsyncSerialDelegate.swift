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

/// Delivers notifications to one weakly held delegate, one at a time, in call order: every
/// notification joins a single FIFO drained by one consumer task, so calls made in sequence reach
/// the delegate in that sequence.
final class AsyncSerialDelegate<T: Sendable>: Sendable {
    private struct State {
        weak var delegate: AnyObject?
    }

    private typealias Notify = @Sendable (T) async -> Void

    private let _state: StateSync<State>
    private let _notifications: AsyncStream<Notify>.Continuation

    init() {
        let state = StateSync(State())
        let (notifications, continuation) = AsyncStream.makeStream(of: Notify.self)
        _state = state
        _notifications = continuation
        // Captures the state and the stream, not self, so it cannot keep this object alive. It
        // ends on its own once `deinit` finishes the stream and what was queued has been delivered;
        // cancelling it instead would run those last deliveries on a cancelled task.
        Task.detached {
            for await notify in notifications {
                guard let delegate = state.read({ $0.delegate }) as? T else { continue }
                await notify(delegate)
            }
        }
    }

    deinit {
        _notifications.finish()
    }

    func set(delegate: T) {
        _state.mutate { $0.delegate = delegate as AnyObject }
    }

    /// Queues `fnc` behind every notification queued before it and returns at once. Skipped if the
    /// delegate is gone by the time its turn comes.
    func notifyDetached(_ fnc: @Sendable @escaping (T) async -> Void) {
        _notifications.yield(fnc)
    }
}
