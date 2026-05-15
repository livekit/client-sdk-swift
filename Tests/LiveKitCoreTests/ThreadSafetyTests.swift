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
struct ThreadSafetyTests {
    struct TestState: Equatable {
        var dictionary = [String: String]()
        var counter = 0
    }

    @Test func safe() async {
        let queueCount = 100
        let blockCount = 1000
        let safeState = StateSync(TestState())
        let group = DispatchGroup()
        let concurrentQueues = (1 ... queueCount).map { DispatchQueue(label: "testQueue_\($0)", attributes: [.concurrent]) }

        for queue in concurrentQueues {
            for i in 1 ... blockCount {
                queue.async(group: group) {
                    let interval = 0.1 / Double.random(in: 1 ... 100)
                    Thread.sleep(forTimeInterval: interval)

                    safeState.mutate {
                        $0.dictionary["key"] = "\(i)"
                        $0.counter += 1
                    }
                }

                queue.async(group: group) {
                    _ = safeState.counter
                }
            }
        }

        await withCheckedContinuation { continuation in
            group.notify(queue: .main) {
                continuation.resume()
            }
        }

        let totalBlocks = queueCount * blockCount
        #expect(safeState.counter == totalBlocks, "counter must be \(totalBlocks)")
    }
}
