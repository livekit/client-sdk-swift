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
            try await withThrowingTaskGroup(of: Void.self) { group in
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
            try await withThrowingTaskGroup(of: Void.self) { group in
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
        await waitForRegistration(of: completer)

        completer.reset(throwing: LiveKitError(.network, message: "transport failed"))

        let error = await #expect(throws: LiveKitError.self) {
            try await task.value
        }
        #expect(error?.type == .network)
    }

    @Test func taskCancellationStillProducesCancelled() async {
        let completer = AsyncCompleter<Void>(label: "task-cancel", defaultTimeout: 30)
        let task = Task { try await completer.wait() }
        await waitForRegistration(of: completer)

        task.cancel()

        let error = await #expect(throws: LiveKitError.self) {
            try await task.value
        }
        #expect(error?.type == .cancelled)
    }

    @Test func resetClearsResultForReuse() async throws {
        let completer = AsyncCompleter<Void>(label: "reuse-after-throw", defaultTimeout: 30)

        let firstTask = Task { try await completer.wait() }
        await waitForRegistration(of: completer)
        completer.reset(throwing: LiveKitError(.network))
        _ = await firstTask.result

        let secondTask = Task { try await completer.wait() }
        await waitForRegistration(of: completer)
        completer.resume(returning: ())
        try await secondTask.value
    }
}

private func waitForRegistration(of completer: AsyncCompleter<some Any>) async {
    while completer.waiterCount == 0 {
        await Task.yield()
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

        await waitForRegistration(of: completerA)
        await waitForRegistration(of: completerB)

        await map.reset(throwing: LiveKitError(.network, message: "fan-out"))

        let errorA = await #expect(throws: LiveKitError.self) { try await taskA.value }
        let errorB = await #expect(throws: LiveKitError.self) { try await taskB.value }
        #expect(errorA?.type == .network)
        #expect(errorB?.type == .network)
    }

    @Test func resetWithoutErrorDefaultsToCancelled() async {
        let map = CompleterMapActor<Void>(label: "map-test", defaultTimeout: 30)
        let completer = await map.completer(for: "a")
        let task = Task { try await completer.wait() }

        await waitForRegistration(of: completer)

        await map.reset()

        let error = await #expect(throws: LiveKitError.self) { try await task.value }
        #expect(error?.type == .cancelled)
    }
}
