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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.concurrency))
struct CompleterTests {
    @Test func completerReuse() async throws {
        let completer = AsyncCompleter<Void>(label: "Test01", defaultTimeout: 1)
        do {
            try await completer.wait()
        } catch let error as LiveKitError where error.type == .timedOut {
            print("Timed out 1")
        }
        // Re-use
        do {
            try await completer.wait()
        } catch let error as LiveKitError where error.type == .timedOut {
            print("Timed out 2")
        }
    }

    @Test func completerCancel() async throws {
        let completer = AsyncCompleter<Void>(label: "cancel-test", defaultTimeout: 30)
        do {
            // Run Tasks in parallel
            try await withThrowingTaskGroup { group in
                group.addTask {
                    print("Task 1: Waiting...")
                    try await completer.wait()
                }

                group.addTask {
                    print("Timer task: Started...")
                    // Cancel after 3 seconds
                    try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                    print("Timer task: Cancelling...")
                    completer.reset()
                }

                try await group.waitForAll()
            }
        } catch let error as LiveKitError where error.type == .timedOut {
            print("Completer timed out")
        } catch let error as LiveKitError where error.type == .cancelled {
            print("Completer cancelled")
        } catch {
            print("Unknown error: \(error)")
        }
    }

    @Test func completerConcurrentWait() async throws {
        let completer = AsyncCompleter<Void>(label: "cancel-test", defaultTimeout: 30)
        do {
            // Run Tasks in parallel
            try await withThrowingTaskGroup { group in
                group.addTask {
                    print("Task 1: Waiting...")
                    try await completer.wait()
                    print("Task 1: Completed")
                }

                group.addTask {
                    print("Task 2: Waiting...")
                    try await completer.wait()
                    print("Task 2: Completed")
                }

                group.addTask {
                    print("Task 3: Waiting...")
                    try await completer.wait()
                    print("Task 3: Completed")
                }

                group.addTask {
                    print("Timer task: Started...")
                    // Cancel after 3 seconds
                    try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                    print("Timer task: Completing...")
                    completer.resume(returning: ())
                }

                try await group.waitForAll()
            }
        } catch let error as LiveKitError where error.type == .timedOut {
            print("Completer timed out")
        } catch let error as LiveKitError where error.type == .cancelled {
            print("Completer cancelled")
        } catch {
            print("Unknown error: \(error)")
        }
    }

    @Test func resetThrowingPropagatesTypedError() async {
        let completer = AsyncCompleter<Void>(label: "reset-throwing", defaultTimeout: 30)
        let task = Task { try await completer.wait() }
        await completer.waitForRegistration()

        completer.reset(throwing: LiveKitError(.network, message: "transport failed"))

        await #expect {
            try await task.value
        } throws: { ($0 as? LiveKitError)?.type == .network }
    }

    @Test func taskCancellationStillProducesCancelled() async {
        let completer = AsyncCompleter<Void>(label: "task-cancel", defaultTimeout: 30)
        let task = Task { try await completer.wait() }
        await completer.waitForRegistration()

        task.cancel()

        await #expect {
            try await task.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }

    @Test func resetClearsResultForReuse() async throws {
        let completer = AsyncCompleter<Void>(label: "reuse-after-throw", defaultTimeout: 30)

        let firstTask = Task { try await completer.wait() }
        await completer.waitForRegistration()
        completer.reset(throwing: LiveKitError(.network))
        _ = await firstTask.result

        let secondTask = Task { try await completer.wait() }
        await completer.waitForRegistration()
        completer.resume(returning: ())
        try await secondTask.value
    }
}

@Suite(.tags(.concurrency))
struct CompleterMapActorTests {
    @Test func resetThrowingFanOutsTypedErrorToAllCompleters() async {
        let map = CompleterMapActor<Void>(label: "map-test", defaultTimeout: 30)

        let completerA = await map.completer(for: "a")
        let completerB = await map.completer(for: "b")

        let taskA = Task { try await completerA.wait() }
        let taskB = Task { try await completerB.wait() }

        await completerA.waitForRegistration()
        await completerB.waitForRegistration()

        await map.reset(throwing: LiveKitError(.network, message: "fan-out"))

        await #expect {
            try await taskA.value
        } throws: { ($0 as? LiveKitError)?.type == .network }
        await #expect {
            try await taskB.value
        } throws: { ($0 as? LiveKitError)?.type == .network }
    }

    @Test func resetWithoutErrorDefaultsToCancelled() async {
        let map = CompleterMapActor<Void>(label: "map-test", defaultTimeout: 30)
        let completer = await map.completer(for: "a")
        let task = Task { try await completer.wait() }

        await completer.waitForRegistration()

        await map.reset()

        await #expect {
            try await task.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }

    @Test func resumeThrowingForMissingKeyIsNoOp() async throws {
        let map = CompleterMapActor<Void>(label: "no-op-test", defaultTimeout: 30)

        // No completer for the key yet — resume(throwing:) must not auto-create.
        await map.resume(throwing: LiveKitError(.participantRemoved), for: "absent")

        // Subsequent wait on the same key must NOT see a stale "remembered" failure.
        let completer = await map.completer(for: "absent")
        let task = Task { try await completer.wait() }
        await completer.waitForRegistration()
        completer.resume(returning: ())
        try await task.value
    }

    @Test func resumeReturningForMissingKeyRemembersSuccess() async throws {
        let map = CompleterMapActor<Void>(label: "remember-success", defaultTimeout: 30)

        // resume(returning:) on a missing key creates and remembers the value.
        await map.resume(returning: (), for: "key")

        // A later wait must see the success immediately.
        let completer = await map.completer(for: "key")
        try await completer.wait()
    }

    @Test func resumeThrowingReachesExistingWaiter() async {
        let map = CompleterMapActor<Void>(label: "existing-waiter", defaultTimeout: 30)

        let completer = await map.completer(for: "key")
        let task = Task { try await completer.wait() }
        await completer.waitForRegistration()

        await map.resume(throwing: LiveKitError(.network), for: "key")

        await #expect {
            try await task.value
        } throws: { ($0 as? LiveKitError)?.type == .network }
    }
}
