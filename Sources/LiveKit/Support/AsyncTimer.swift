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

actor AsyncTimer: Loggable {
    // MARK: - Public types

    typealias TimerBlock = () async throws -> Void

    // MARK: - Private

    private let _interval: TimeInterval
    private var _task: Task<Void, Never>?
    private var _block: TimerBlock?
    private var _isStarted: Bool = false

    init(interval: TimeInterval) {
        _interval = interval
    }

    deinit {
        _isStarted = false
        _task?.cancel()
        log()
    }

    func cancel() {
        _isStarted = false
        _task?.cancel()
    }

    /// Block must not retain self
    func setTimerBlock(block: @escaping TimerBlock) {
        _block = block
    }

    private func _invoke() async {
        if !_isStarted { return }
        _task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self._interval * 1_000_000_000))
            if await !(self._isStarted) || Task.isCancelled { return }
            try? await self._block?()
            await self._invoke()
        }
    }

    func start() async {
        _task?.cancel()
        _isStarted = true
        await _invoke()
    }
}
