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

@Suite(.tags(.networking), TestLimits.e2e)
struct WebSocketResetTests {
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1179"))
    func peerResetTearsDownBeforeTheReadFailsUnderLoad() async throws {
        let completed = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    for _ in 0 ..< 300 {
                        try await WebSocketLifecycleTests().peerClosure(behavior: .reset, ending: .networkError(posix: ECONNRESET))
                    }
                    return 300
                }
            }
            var rounds = 0
            for try await count in group {
                rounds += count
            }
            return rounds
        }
        #expect(completed == 2400)
        print("Reset stress: 8 concurrent loops × 300 rounds = \(completed) completed")
    }
}
