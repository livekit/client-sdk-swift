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

/// Actor that implements debouncing of async operations
///
/// Debouncing ensures that rapid, repeated calls to an operation will only execute
/// after a specified delay has elapsed since the most recent call.
actor Debounce {
    private var _task: Task<Void, Never>?
    private let _delay: TimeInterval
    private var _nonce = 0 // Used to track the latest scheduled task

    /// Initialize with a specified delay
    /// - Parameter delay: The time to wait after the last call before executing
    init(delay: TimeInterval) {
        _delay = delay
    }

    deinit {
        _task?.cancel()
    }

    /// Cancel any pending operations
    func cancel() {
        _task?.cancel()
        _task = nil
    }

    /// Schedule an operation to be executed after the debounce delay
    /// - Parameter action: The operation to execute
    /// - Returns: A Task representing the scheduled operation
    @discardableResult
    func schedule(_ action: @Sendable @escaping () async throws -> Void) -> Task<Void, Never> {
        // Cancel any existing task
        _task?.cancel()

        // Create a nonce to identify this particular schedule call
        let currentNonce = _nonce
        _nonce += 1

        // Create and store the new task
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            do {
                // Wait for the debounce delay
                try await Task.sleep(nanoseconds: UInt64(self._delay * 1_000_000_000))

                // Check if this task is still the active one
                let isStillValid = await self.isTaskStillValid(nonce: currentNonce)
                guard isStillValid, !Task.isCancelled else { return }

                // Execute the action
                try await action()
            } catch {
                // Ignore cancellation and sleep errors
                if !error.isSleepCancellationError {
                    print("Debounce action error: \(error)")
                }
            }
        }

        _task = task
        return task
    }

    /// Checks if a task with the given nonce is still the active task
    private func isTaskStillValid(nonce: Int) -> Bool {
        nonce == _nonce - 1
    }
}

private extension Error {
    var isSleepCancellationError: Bool {
        let nsError = self as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == 4
    }
}
