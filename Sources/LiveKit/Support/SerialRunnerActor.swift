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

actor SerialRunnerActor<Value: Sendable> {
    private var previousTask: Task<Value, Error>?

    func run(block: @Sendable @escaping () async throws -> Value) async throws -> Value {
        let task = Task { [previousTask] in
            // Wait for the previous task to complete, but cancel it if needed
            if let previousTask, !Task.isCancelled {
                // If previous task is still running, wait for it
                _ = try? await previousTask.value
            }

            // Check for cancellation before running the block
            try Task.checkCancellation()

            // Run the new block
            return try await block()
        }

        previousTask = task

        return try await withTaskCancellationHandler {
            // Await the current task's result
            try await task.value
        } onCancel: {
            // Ensure the task is canceled when requested
            task.cancel()
        }
    }
}
