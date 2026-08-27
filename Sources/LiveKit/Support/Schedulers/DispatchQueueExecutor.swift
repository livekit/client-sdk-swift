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

/// Runs an actor's jobs on a dispatch queue instead of the cooperative pool, so code isolated to
/// that actor may make calls that block on another thread.
final class DispatchQueueExecutor: SerialExecutor {
    let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    // The runtime's isolation check on iOS 18 / macOS 15-era runtimes (e.g. Xcode 16.4) routes
    // here; without an override the stdlib default traps unconditionally ("Unexpected isolation
    // context, expected to be executing on DispatchQueueExecutor"). This passes when the caller is
    // genuinely on the queue and traps only on a real violation. The `@available` matches the
    // requirement — below these versions the hook does not exist and the runtime never calls it;
    // newer runtimes (macOS 26+) query the non-trapping `isIsolatingCurrentContext()` default and
    // never reach this at all.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
