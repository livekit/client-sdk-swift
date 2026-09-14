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

@testable import LiveKit
import Testing

extension AsyncCompleter {
    /// Yields until at least one waiter has parked on this completer — used
    /// when a Task awaits on a completer and the test needs to act only after
    /// the wait has parked.
    func waitForRegistration() async {
        while waiterCount == 0 {
            await Task.yield()
        }
    }
}

struct AsyncCompleterCancellationTests {
    /// A waiter cancelled while its own timeout is firing must settle, not deadlock: the first child
    /// to time out cancels the rest at the very moment their timers go off.
    @Test func cancelRacingTimeoutSettles() async throws {
        let races = Task.detached {
            for _ in 0 ..< 2000 {
                let first = AsyncCompleter<Void>(label: "first", defaultTimeout: 1)
                let second = AsyncCompleter<Void>(label: "second", defaultTimeout: 1)
                _ = try? await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await first.wait(timeout: 0.001) }
                    group.addTask { try await second.wait(timeout: 0.001) }
                    for try await _ in group.prefix(1) {
                        group.cancelAll()
                    }
                }
            }
        }
        // Bounded by a completer of its own, so a regression fails the test instead of the job.
        let finished = AsyncCompleter<Void>(label: "races", defaultTimeout: 30)
        Task.detached { await races.value; finished.resume(returning: ()) }
        try await finished.wait()
    }
}
