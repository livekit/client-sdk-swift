/*
 * Copyright 2025 LiveKit
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

    struct State: Sendable {
        var isStarted: Bool = false
        var interval: TimeInterval
        var task: Task<Void, Never>?
        var block: TimerBlock?
    }

    let _state: StateSync<State>

    init(interval: TimeInterval) {
        _state = StateSync(State(interval: interval))
    }

    deinit {
        _state.mutate {
            $0.isStarted = false
            $0.task?.cancel()
        }
    }

    func cancel() {
        _state.mutate {
            $0.isStarted = false
            $0.task?.cancel()
        }
    }

    /// Block must not retain self
    func setTimerBlock(block: @escaping TimerBlock) {
        _state.mutate {
            $0.block = block
        }
    }

    /// Update timer interval
    func setTimerInterval(_ timerInterval: TimeInterval) {
        _state.mutate {
            $0.interval = timerInterval
        }
    }

    private func scheduleNextInvocation() async {
        let state = _state.copy()
        guard state.isStarted else { return }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(state.interval * 1_000_000_000))
            if !state.isStarted || Task.isCancelled { return }
            do {
                try await state.block?()
            } catch {
                log("Error in timer block: \(error)", .error)
            }
            await scheduleNextInvocation()
        }
        _state.mutate { $0.task = task }
    }

    func restart() {
        _state.mutate {
            $0.task?.cancel()
            $0.isStarted = true
        }

        Task { await scheduleNextInvocation() }
    }
}
