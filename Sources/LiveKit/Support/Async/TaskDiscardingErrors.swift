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

private enum DiscardingTask: Loggable {}

extension Task where Success == Void, Failure == Never {
    /// Spawn an unstructured task whose thrown errors are discarded.
    ///
    /// Non-cancellation errors are logged via the shared logger;
    /// `CancellationError` is dropped silently.
    @discardableResult
    static func discardingErrors(
        priority: TaskPriority? = nil,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async throws -> Void
    ) -> Task<Void, Never> {
        Task(priority: priority) {
            do {
                try await operation()
            } catch is CancellationError {
                // intentionally discarded
            } catch {
                DiscardingTask.log("Task error: \(error)", .error,
                                   file: file, function: function, line: line)
            }
        }
    }
}
