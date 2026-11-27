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

/// Awaits `operation`, a native call that ignores task cancellation and that only `cancel` wakes.
///
/// When the calling task is cancelled, `cancel` runs one time in a detached task, and this call
/// joins that task before it throws `CancellationError`. `cancel` wakes a native future, so it must
/// run outside the cancellation handler's task status-record lock: with UniFFI 0.31 the wake can
/// deadlock there. The detached task is joined, never cancelled or abandoned.
func cancellingNative<T>(_ cancel: @escaping @Sendable () -> Void,
                         _ operation: () async throws -> T) async throws -> T
{
    let cancelling = StateSync<Task<Void, Never>?>(nil)
    let scheduleCancel: @Sendable () -> Task<Void, Never> = {
        cancelling.mutate { task in
            if let task { return task }
            let started = Task.detached { cancel() }
            task = started
            return started
        }
    }
    do {
        let value = try await withTaskCancellationHandler(operation: operation, onCancel: {
            _ = scheduleCancel()
        })
        try Task.checkCancellation()
        return value
    } catch {
        guard Task.isCancelled else { throw error }
        await scheduleCancel().value
        throw CancellationError()
    }
}

/// A native pull cursor (`next` and an idempotent `cancel`) as an `AsyncSequence`.
///
/// - It pulls only when the consumer asks. No buffer sits in between, so the bound and the
///   coalescing of the native cursor reach the consumer intact.
/// - It wraps a cursor that already exists. To iterate does not create a cursor, so a second
///   iteration continues the same one.
/// - Task cancellation cancels the cursor through ``cancellingNative(_:_:)``.
/// - A loop that exits early releases only the iterator. The owner of the cursor cancels it.
struct Pull<Element: Sendable>: AsyncSequence, AsyncIteratorProtocol, Sendable {
    private let pull: @Sendable () async throws -> Element?
    private let cancel: @Sendable () -> Void

    init(_ next: @escaping @Sendable () async throws -> Element?, cancel: @escaping @Sendable () -> Void) {
        pull = next
        self.cancel = cancel
    }

    func makeAsyncIterator() -> Pull { self }

    func next() async throws -> Element? {
        try await cancellingNative(cancel, pull)
    }
}
