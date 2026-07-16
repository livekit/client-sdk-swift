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

final class AsyncTimer: Sendable, Loggable {
    // MARK: - Public types

    typealias TimerBlock = @Sendable () async throws -> Void

    // MARK: - Private

    struct State {
        var interval: TimeInterval
        // Non-nil means running. Reassigning or clearing cancels the previous task:
        // AnyTaskCancellable cancels its Task on deinit (like Combine's AnyCancellable).
        var task: AnyTaskCancellable?
        var block: TimerBlock?
    }

    let _state: StateSync<State>

    init(interval: TimeInterval) {
        _state = StateSync(State(interval: interval))
    }

    deinit {
        _state.mutate { $0.task = nil }
    }

    func cancel() {
        _state.mutate { $0.task = nil }
    }

    /// Block must not retain self
    func setTimerBlock(block: @escaping TimerBlock) {
        _state.mutate { $0.block = block }
    }

    /// Update timer interval
    func setTimerInterval(_ timerInterval: TimeInterval) {
        _state.mutate { $0.interval = timerInterval }
    }

    private func makeLoopTask() -> AnyTaskCancellable {
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let (interval, block) = _state.read { ($0.interval, $0.block) }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                do {
                    try await block?()
                } catch {
                    log("Error in timer block: \(error)", .error)
                }
            }
        }.cancellable()
    }

    func restart() {
        _state.mutate { $0.task = makeLoopTask() }
    }

    /// Starts the timer only if not already running, leaving an in-flight countdown untouched.
    func startIfStopped() {
        _state.mutate {
            guard $0.task == nil else { return }
            $0.task = makeLoopTask()
        }
    }
}
