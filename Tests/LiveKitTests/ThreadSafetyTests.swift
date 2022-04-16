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

class ThreadSafetyTests: XCTestCase {

    struct TestState {
        var dictionary = [String: String]()
        var counter = 0
    }

    let queueCount = 10
    let blockCount = 100
    
    let safeState = StateSync(TestState())
    var unsafeState = TestState()

    let group = DispatchGroup()
    var concurrentQueues = [DispatchQueue]()
    
    override func setUpWithError() throws {
        concurrentQueues = Array(1...queueCount).map { DispatchQueue(label: "testQueue_\($0)", attributes: [.concurrent]) }
    }

    
    override func tearDown() async throws {
        //
        concurrentQueues = []

        safeState.mutate { $0 = TestState() }
        unsafeState = TestState()
    }

    // this should never crash
    func testSafe() async throws {

        for queue in concurrentQueues {
            for i in 1...blockCount {
                queue.async(group: group) {
                    self.safeState.mutate {
                        $0.dictionary["key"] = "\(i)"
                        $0.counter += 1
                    }
                }
            }
        }
        
        await withCheckedContinuation { continuation in
            group.notify(queue: .main) {
                continuation.resume()
            }
        }
        
        print("state \(safeState)")
        
        let totalBlocks = queueCount * blockCount
        XCTAssert(safeState.counter == totalBlocks, "counter must be \(totalBlocks)")
    }

    // this will crash
    func testUnsafe() async throws {

        for queue in concurrentQueues {
            for i in 1...blockCount {
                queue.async(group: group) {
                    // high possibility it will crash here
                    self.unsafeState.dictionary["key"] = "\(i)"
                    self.unsafeState.counter += 1
                }
            }
        }
        
        await withCheckedContinuation { continuation in
            group.notify(queue: .main) {
                continuation.resume()
            }
        }
        
        print("state \(unsafeState)")
        
        let totalBlocks = queueCount * blockCount
        XCTAssert(unsafeState.counter == totalBlocks, "counter must be \(totalBlocks)")
    }
}
