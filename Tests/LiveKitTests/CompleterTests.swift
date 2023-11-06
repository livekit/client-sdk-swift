/*
 * Copyright 2023 LiveKit
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

class CompleterTests: XCTestCase {
    override func setUpWithError() throws {}

    override func tearDown() async throws {}

    func testCompleterReuse() async throws {
        let completer = AsyncCompleter<Void>(label: "Test01", timeOut: .seconds(1))
        do {
            try await completer.wait()
        } catch AsyncCompleterError.timedOut {
            print("Timed out 1")
        }
        // Re-use
        do {
            try await completer.wait()
        } catch AsyncCompleterError.timedOut {
            print("Timed out 2")
        }
    }

    func testCompleterCancel() async throws {
        let completer = AsyncCompleter<Void>(label: "cancel-test", timeOut: .never)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in

                group.addTask {
                    print("Task 1: Waiting...")
                    try await completer.wait()
                }

                group.addTask {
                    print("Task 2: Started...")
                    // Cancel after 1 second
                    try await Task.sleep(until: .now + .seconds(1), clock: .continuous)
                    print("Task 2: Cancelling completer...")
                    completer.cancel()
                }

                try await group.waitForAll()
            }
        } catch let error as AsyncCompleterError where error == .timedOut {
            print("Completer timed out")
        } catch let error as AsyncCompleterError where error == .cancelled {
            print("Completer cancelled")
        } catch {
            print("Unknown error: \(error)")
        }
    }
}
