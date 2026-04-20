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

@Suite(.serialized, .tags(.concurrency))
struct SerialRunnerActorTests {
    // The original tests verified that SerialRunnerActor serializes
    // concurrent work by mutating shared state (counter, result array)
    // from inside `serialRunner.run { }`. The serial runner guarantees
    // only one closure runs at a time, so direct mutation is safe.
    // We use StateSync to satisfy Sendable without @unchecked.

    @Test func serialRunner() async throws {
        let serialRunner = SerialRunnerActor<Void>()
        let counter = StateSync(0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1 ... 1000 {
                group.addTask {
                    try await serialRunner.run {
                        counter.mutate { $0 += 1 }
                        let ns = UInt64(Double.random(in: 1 ..< 3) * 1_000_000)
                        print("task \(i) start, will wait \(ns)ns")
                        try await Task.sleep(nanoseconds: ns)
                        print("task \(i) done")
                        counter.mutate { $0 -= 1 }
                    }
                }
            }

            try await group.waitForAll()
        }

        #expect(counter.copy() == 0, "Counter should be 0 after balanced increments/decrements")
    }

    @Test func serialRunnerCancel() async {
        let serialRunner = SerialRunnerActor<Void>()
        let counter = StateSync(0)

        await withTaskGroup(of: Void.self) { group in
            for i in 1 ... 1000 {
                group.addTask {
                    let subTask = Task {
                        do {
                            try await serialRunner.run {
                                counter.mutate { $0 += 1 }
                                defer {
                                    counter.mutate { $0 -= 1 }
                                }

                                let ns = UInt64(Double.random(in: 1 ..< 3) * 1_000_000)
                                print("task \(i) start, will wait \(ns)ns")
                                try await Task.sleep(nanoseconds: ns)
                                print("task \(i) done")
                            }
                        } catch {
                            print("Task \(i) was cancelled")
                        }
                    }

                    if Bool.random() {
                        subTask.cancel()
                    }

                    return await subTask.value
                }
            }

            await group.waitForAll()
        }

        #expect(counter.copy() == 0, "Counter should be 0 after balanced increments/decrements")
    }

    @Test func serialRunnerOrderWithCancel() async throws {
        let serialRunner = SerialRunnerActor<Void>()
        let results = StateSync<[String]>([])

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Schedule task 1 (will be cancelled after 1.5s)
            group.addTask {
                let subTask = Task {
                    do {
                        try await serialRunner.run {
                            defer {
                                results.mutate { $0.append("task1") }
                            }
                            let ns = UInt64(3 * 1_000_000_000)
                            try await Task.sleep(nanoseconds: ns)
                        }
                    } catch {
                        print("Task 1 threw \(error)")
                    }
                }

                try await Task.sleep(nanoseconds: UInt64(1.5 * 1_000_000_000))
                subTask.cancel()
                return await subTask.value
            }

            // Schedule task 2
            try await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
            group.addTask {
                try await serialRunner.run {
                    results.mutate { $0.append("task2") }
                }
            }

            // Schedule task 3
            try await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
            group.addTask {
                try await serialRunner.run {
                    results.mutate { $0.append("task3") }
                }
            }

            try await group.waitForAll()
        }

        #expect(results.copy() == ["task1", "task2", "task3"], "Tasks should complete in order")
    }
}
