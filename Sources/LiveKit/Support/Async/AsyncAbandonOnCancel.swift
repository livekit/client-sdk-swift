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

/// Awaits `operation`, or throws `CancellationError` as soon as the calling task is cancelled,
/// whichever comes first.
///
/// For calls that ignore cancellation, such as the UniFFI async bridge, which has no cancel hook.
/// `operation` runs in its own task, so a cancel ends the wait, not the call.
func abandoningOnCancel<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    // The result and the cancel race to take the continuation; the loser finds `nil`.
    let pending = StateSync<CheckedContinuation<T, Error>?>(nil)
    let take: @Sendable () -> CheckedContinuation<T, Error>? = {
        pending.mutate { continuation in
            defer { continuation = nil }
            return continuation
        }
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            pending.mutate { $0 = continuation }
            // A task cancelled before the store above already ran `onCancel`, which found nothing.
            guard !Task.isCancelled else {
                take()?.resume(throwing: CancellationError())
                return
            }
            // ponytail: an abandoned call stays pending until its stream ends or the room tears
            // down. Stopping it needs a cancel hook in the UniFFI bridge.
            Task {
                do {
                    let value = try await operation()
                    take()?.resume(returning: value)
                } catch {
                    take()?.resume(throwing: error)
                }
            }
        }
    } onCancel: {
        take()?.resume(throwing: CancellationError())
    }
}
