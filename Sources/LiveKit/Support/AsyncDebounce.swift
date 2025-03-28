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

actor Debounce {
    private var _task: Task<Void, Never>?
    private let _delay: TimeInterval

    init(delay: TimeInterval) {
        _delay = delay
    }

    deinit {
        _task?.cancel()
    }

    func cancel() {
        _task?.cancel()
    }

    func schedule(_ action: @Sendable @escaping () async throws -> Void) {
        _task?.cancel()
        _task = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(self._delay * 1_000_000_000))
            if !Task.isCancelled {
                try? await action()
            }
        }
    }
}
