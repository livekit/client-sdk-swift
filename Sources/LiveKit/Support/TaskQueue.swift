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

/// An actor that ensures sequential execution of tasks
actor TaskQueue: Loggable {
    private var isProcessing = false
    private var pendingTasks = [CheckedContinuation<Void, Error>]()

    init() {}

    /// Enqueues an operation for execution
    /// If the queue is idle, executes immediately
    /// Otherwise, waits for turn in the queue
    func enqueue<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        // Fast path - if not processing, execute immediately
        if !isProcessing {
            return try await executeOperation(operation)
        }

        // Wait for turn
        try await withCheckedThrowingContinuation { continuation in
            pendingTasks.append(continuation)
        }

        // Now it's our turn
        return try await executeOperation(operation)
    }

    /// Execute operation with proper processing state management
    private func executeOperation<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        isProcessing = true

        // Make sure we reset the state and process pending tasks in all code paths
        defer {
            isProcessing = false
            processPending()
        }

        // Perform the operation
        return try await operation()
    }

    private func processPending() {
        guard !pendingTasks.isEmpty else { return }
        let next = pendingTasks.removeFirst()
        next.resume()
    }
}
