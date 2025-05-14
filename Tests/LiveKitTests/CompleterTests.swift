/*
 * Copyright 2025 LiveKit
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

class CompleterTests: LKTestCase {
    override func setUpWithError() throws {}

    override func tearDown() async throws {}

    func testCompleterReuse() async throws {
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

    func testCompleterCancel() async throws {
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

    func testCompleterConcurrentWait() async throws {
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
}
