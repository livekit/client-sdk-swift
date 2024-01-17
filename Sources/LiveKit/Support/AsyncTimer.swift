/*
 * Copyright 2024 LiveKit
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

actor AsyncTimer {
    typealias TimerBlock = () async throws -> Void

    private let _delay: TimeInterval
    private var _task: Task<Void, Never>?
    private var _block: TimerBlock?

    init(delay: TimeInterval) {
        _delay = delay
    }

    deinit {
        _task?.cancel()
    }

    func cancel() {
        _task?.cancel()
    }

    /// Block must not retain self
    func setTimerBlock(block: @escaping TimerBlock) {
        _block = block
    }

    func start() {
        _task?.cancel()
        _task = Task.detached(priority: .utility) {
            while true {
                try? await Task.sleep(nanoseconds: UInt64(self._delay * 1_000_000_000))
                if Task.isCancelled { break }
                try? await self._block?()
            }
        }
    }
}
