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

final class AsyncSerialDelegate<T: Sendable>: Sendable {
    private struct State {
        weak var delegate: AnyObject?
    }

    private let _state = StateSync(State())
    private let _serialRunner = SerialRunnerActor<Void>()

    func set(delegate: T) {
        _state.mutate { $0.delegate = delegate as AnyObject }
    }

    func notifyAsync(_ fnc: @Sendable @escaping (T) async -> Void) async throws {
        guard let delegate = _state.read({ $0.delegate }) as? T else { return }
        try await _serialRunner.run {
            await fnc(delegate)
        }
    }

    func notifyDetached(_ fnc: @Sendable @escaping (T) async -> Void) {
        Task.detached {
            try await self.notifyAsync(fnc)
        }
    }
}
