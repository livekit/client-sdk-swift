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

@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class QueueActorTests: LKTestCase {
    private lazy var queue = QueueActor<String> { print($0) }

    override func setUpWithError() throws {}

    override func tearDown() async throws {}

    func testQueueActor01() async throws {
        await queue.processIfResumed("Value 0")
        await queue.suspend()
        await queue.processIfResumed("Value 1")
        await queue.processIfResumed("Value 2")
        await queue.processIfResumed("Value 3")
        await print("Count: \(queue.count)")
        await queue.resume()
        await print("Count: \(queue.count)")
    }
}
