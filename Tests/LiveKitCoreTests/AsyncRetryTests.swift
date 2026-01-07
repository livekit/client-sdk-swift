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

class AsyncRetryTests: LKTestCase {
    override func setUpWithError() throws {}

    override func tearDown() async throws {}

//    func testRetry1() async throws {
//        let test = Task.retrying(totalAttempts: 3) { currentAttempt, totalAttempts in
//            print("[TEST] Retrying with remaining attemps: \(currentAttempt)/\(totalAttempts)...")
//            throw LiveKitError(.invalidState, message: "Test error")
//        }
//
//        let value: () = try await test.value
//        print("[TEST] Ended with value: '\(value)'...")
//    }
}
