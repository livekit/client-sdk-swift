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

actor AsyncSerialDelegate<T>: Loggable {
    public weak var _delegate: AnyObject?

    // This is isolated so will execute serially
    private func invoke(_ fnc: @escaping (T) async -> Void) async {
        guard let delegate = _delegate as? T else { return }
        await fnc(delegate)
    }

    private func _set(delegate: T) {
        _delegate = delegate as AnyObject
    }

    nonisolated func set(delegate: T) {
        Task.detached {
            await self._set(delegate: delegate)
        }
    }

    /// Notify delegates inside the queue.
    /// Label is captured inside the queue for thread safety reasons.
    nonisolated
    func notifyAsync(label _: (() -> String)? = nil, _ fnc: @escaping (T) async -> Void) {
        Task.detached {
            await self.invoke(fnc)
        }
    }
}
