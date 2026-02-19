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
class SerialRunnerActorTests: @unchecked Sendable {
    let serialRunner = SerialRunnerActor<Void>()
    var counterValue: Int = 0
    var resultValues: [String] = []

    // Test whether tasks, when invoked concurrently, continue to run in a serial manner.
    // Access to the counter value should be synchronized, aiming for a final count of 0.
    @Test func serialRuuner() async throws {
        // Run Tasks concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1 ... 1000 {
                group.addTask {
                    try await self.serialRunner.run {
                        self.counterValue += 1
                        let ns = UInt64(Double.random(in: 1 ..< 3) * 1_000_000)
                        print("executor1 task \(i) start, will wait \(ns)ns")
                        // Simulate random-ish time consuming task
                        try await Task.sleep(nanoseconds: ns)
                        print("executor1 task \(i) done")
                        self.counterValue -= 1
                    }
                }
            }

            try await group.waitForAll()
        }

        print("serialExecutor1Counter: \(counterValue)")
        // Should end up being 0
        #expect(counterValue == 0)
    }

    // Test whether tasks invoked concurrently, and randomly cancelled, continue to run in a serial manner.
    // Access to the counter value should be synchronized, resulting in a count of 0.
    @Test func serialRunnerCancel() async {
        // Run Tasks concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 1 ... 1000 {
                group.addTask {
                    let subTask = Task {
                        do {
                            try await self.serialRunner.run {
                                // Increment counter
                                self.counterValue += 1
                                defer {
                                    // Decrement counter
                                    self.counterValue -= 1
                                }

                                let ns = UInt64(Double.random(in: 1 ..< 3) * 1_000_000)
                                print("executor1 task \(i) start, will wait \(ns)ns")
                                // Simulate random-ish time consuming task
                                try await Task.sleep(nanoseconds: ns)

                                print("executor1 task \(i) done")
                            }
                        } catch {
                            // Handle exceptions so test will continue
                            print("Task \(i) was cancelled")
                        }
                    }

                    // Cancel randomly
                    if Bool.random() {
                        print("Cancelling task \(i)...")
                        subTask.cancel()
                    }

                    return await subTask.value
                }
            }

            await group.waitForAll()
        }

        print("serialExecutor1Counter: \(counterValue)")
        // Should end up being 0
        #expect(counterValue == 0)
    }

    @Test func serialRunnerOrderWithCancel() async throws {
        // Run Tasks concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Schedule task 1
            print("Scheduling task 1...")
            group.addTask {
                let subTask = Task {
                    do {
                        try await self.serialRunner.run {
                            defer {
                                self.resultValues.append("task1")
                                print("task 1 done")
                            }
                            // Simulate a long task
                            let ns = UInt64(3 * 1_000_000_000)
                            print("task 1 waiting \(ns)ns...")
                            // Simulate random-ish time consuming task
                            try await Task.sleep(nanoseconds: ns)
                        }
                    } catch {
                        // Handle exceptions so test will continue
                        print("Task 1 throwed \(error)")
                    }
                }

                // Cancel after 1.5 second
                try await Task.sleep(nanoseconds: UInt64(1.5 * 1_000_000_000))
                print("Cancelling task 1...")
                subTask.cancel()

                return await subTask.value
            }

            // Schedule task 2
            try await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
            print("Scheduling task 2...")
            group.addTask {
                try await self.serialRunner.run {
                    self.resultValues.append("task2")
                    print("task 2 done")
                }
            }

            // Schedule task 3
            try await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
            print("Scheduling task 3...")
            group.addTask {
                try await self.serialRunner.run {
                    self.resultValues.append("task3")
                    print("task 3 done")
                }
            }

            try await group.waitForAll()
        }

        print("completed tasks order: \(resultValues)")
        // Should be in order
        #expect(resultValues == ["task1", "task2", "task3"])
    }
}
