/*
 * Copyright 2024 LiveKit
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

@testable import LiveKit
import XCTest

class AsyncSerialExecutorTests: XCTestCase {
    var serialExecutor1Counter: Int = 0
    let serialExecutor1 = AsyncSerialExecutor<Void>()

    func testSerialExecution() async throws {
        // Run Tasks concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1 ... 1000 {
                group.addTask {
                    try await self.serialExecutor1.execute {
                        self.serialExecutor1Counter += 1
                        let ns = UInt64(Double.random(in: 1 ..< 3) * 1_000_000)
                        print("executor1 task \(i) start, will wait \(ns)ns")
                        // Simulate random-ish time consuming task
                        try await Task.sleep(nanoseconds: ns)
                        print("executor1 task \(i) done")
                        self.serialExecutor1Counter -= 1
                    }
                }
            }

            try await group.waitForAll()
        }

        print("serialExecutor1Counter: \(serialExecutor1Counter)")
        // Should end up being 0
        XCTAssert(serialExecutor1Counter == 0)
    }

    func testSerialExecutionCancel() async throws {
        // Run Tasks concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 1 ... 1000 {
                group.addTask {
                    let subTask = Task {
                        do {
                            try await self.serialExecutor1.execute {
                                // Increment counter
                                self.serialExecutor1Counter += 1
                                defer {
                                    // Decrement counter
                                    self.serialExecutor1Counter -= 1
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

        print("serialExecutor1Counter: \(serialExecutor1Counter)")
        // Should end up being 0
        XCTAssert(serialExecutor1Counter == 0)
    }
}
