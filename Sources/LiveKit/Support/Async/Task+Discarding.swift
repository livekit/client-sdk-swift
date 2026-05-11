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
    /// Inherits the caller's actor isolation, priority, and task-local values
    /// (same as `Task.init`). For a variant that detaches from the caller's
    /// context, use `Task.detachedDiscarding`.
    ///
    /// Thrown errors are logged via the shared logger and discarded.
    @discardableResult
    static func discarding(
        priority: TaskPriority? = nil,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async throws -> some Sendable
    ) -> Task<Void, Never> {
        Task(priority: priority) {
            do {
                _ = try await operation()
            } catch {
                DiscardingTask.log("Task error: \(error)", .error,
                                   file: file, function: function, line: line)
            }
        }
    }

    /// Spawn a detached unstructured task whose thrown errors are discarded.
    ///
    /// Does not inherit the caller's actor isolation, priority, or task-local
    /// values (same as `Task.detached`). For a variant that inherits the
    /// caller's context, use `Task.discarding`.
    ///
    /// Thrown errors are logged via the shared logger and discarded.
    @discardableResult
    static func detachedDiscarding(
        priority: TaskPriority? = nil,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        operation: sending @escaping () async throws -> some Sendable
    ) -> Task<Void, Never> {
        Task.detached(priority: priority) {
            do {
                _ = try await operation()
            } catch {
                DiscardingTask.log("Task error: \(error)", .error,
                                   file: file, function: function, line: line)
            }
        }
    }
}
