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

/// Owns a `Task<T, Error>` whose result can be awaited via `value` and whose
/// underlying Task is cancelled when the wrapper deallocates. Use for memoized
/// one-shot async work — first caller runs the work, subsequent callers reuse
/// the cached result; clearing the stored reference cancels the in-flight Task.
final class MemoizedTask<T: Sendable>: Sendable {
    private let task: Task<T, Error>

    init(_ body: @escaping @Sendable () async throws -> T) {
        task = Task { try await body() }
    }

    var value: T {
        get async throws { try await task.value }
    }

    deinit { task.cancel() }
}
