/*
 * Copyright 2022 LiveKit
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

    struct TestState {
        var completer = Completer<String>()
    }

    let safeState = StateSync(TestState())
    var unsafeState = TestState()

    let group = DispatchGroup()
    var concurrentQueues = DispatchQueue(label: "completer")
    
    override func setUpWithError() throws {

    }

    
    override func tearDown() async throws {

    }

    func testCompleter1() async throws {
        
        // safeState.mutate { $0.completer.set(value: "resolved") }
        
        let promise = safeState.mutate { $0.completer.wait(on: concurrentQueues, 3, throw: { EngineError.timedOut(message: "") } ) }
        
        concurrentQueues.async {
            // Thread.sleep(forTimeInterval: 10)
            self.safeState.mutate {
                var completer = $0.completer
                completer.set(value: "done")
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // continuation.resume()
            print("promise waiting...")
            promise.then(on: concurrentQueues) { value in
                print("promise completed value: \(value)")
                continuation.resume()
            }.catch { error in
                print("promise error: \(error)")
                continuation.resume()
            }
        }
    }
}
