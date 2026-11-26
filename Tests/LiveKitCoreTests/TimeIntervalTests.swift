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

struct TimeIntervalTests {
    struct DelayCase: CustomTestStringConvertible {
        let attempt: Int
        let baseDelay: TimeInterval
        let maxDelay: TimeInterval
        let totalAttempts: Int
        let expected: TimeInterval

        var testDescription: String {
            "attempt \(attempt)/\(totalAttempts) (base=\(baseDelay), max=\(maxDelay))"
        }
    }

    /// Tests that the reconnection delay grows with the square of the attempt number, up to maxDelay.
    @Test(arguments: [
        // Default values: baseDelay=0.3, maxDelay=7.0, totalAttempts=10
        DelayCase(attempt: 0, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10, expected: 0.3),
        DelayCase(attempt: 1, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10, expected: 1.2),
        DelayCase(attempt: 2, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10, expected: 2.7),
        DelayCase(attempt: 3, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10, expected: 4.8),
        DelayCase(attempt: 4, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10, expected: 7.0),
        DelayCase(attempt: 9, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10, expected: 7.0),
        // Custom values
        DelayCase(attempt: 0, baseDelay: 1.0, maxDelay: 5.0, totalAttempts: 5, expected: 1.0),
        DelayCase(attempt: 1, baseDelay: 1.0, maxDelay: 5.0, totalAttempts: 5, expected: 4.0),
        DelayCase(attempt: 2, baseDelay: 1.0, maxDelay: 5.0, totalAttempts: 5, expected: 5.0),
        // The last attempt waits maxDelay, also when the curve is still below it
        DelayCase(attempt: 1, baseDelay: 1.0, maxDelay: 5.0, totalAttempts: 2, expected: 5.0),
        // Inverted (baseDelay > maxDelay)
        DelayCase(attempt: 0, baseDelay: 10.0, maxDelay: 5.0, totalAttempts: 5, expected: 5.0),
        DelayCase(attempt: 4, baseDelay: 10.0, maxDelay: 5.0, totalAttempts: 5, expected: 5.0),
    ])
    func computeReconnectDelay(_ c: DelayCase) {
        let actual = TimeInterval.computeReconnectDelay(
            forAttempt: c.attempt,
            baseDelay: c.baseDelay,
            maxDelay: c.maxDelay,
            totalAttempts: c.totalAttempts,
            addJitter: false,
        )

        #expect(abs(actual - c.expected) <= 0.001)
    }

    /// Tests that jitter is properly applied to attempts.
    @Test(arguments: 1 ... 5)
    func reconnectDelayJitter(attempt: Int) {
        let baseDelay = TimeInterval.defaultReconnectDelay
        let maxDelay = TimeInterval.defaultReconnectMaxDelay
        let totalAttempts = 10

        let withoutJitter = TimeInterval.computeReconnectDelay(
            forAttempt: attempt,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            totalAttempts: totalAttempts,
            addJitter: false,
        )

        let withJitter = TimeInterval.computeReconnectDelay(
            forAttempt: attempt,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            totalAttempts: totalAttempts,
            addJitter: true,
        )

        #expect(withJitter > withoutJitter, "Should have jitter applied")
        #expect(withJitter <= withoutJitter * 1.3, "Jitter should not exceed 30% of the delay")
    }

    /// Tests that jitter for the last attempt stays within bounds.
    @Test func reconnectDelayJitterLastAttempt() {
        let baseDelay = TimeInterval.defaultReconnectDelay
        let maxDelay = TimeInterval.defaultReconnectMaxDelay
        let totalAttempts = 10
        let maxJitter = maxDelay * 0.3

        for _ in 0 ..< 10 {
            let delay = TimeInterval.computeReconnectDelay(
                forAttempt: totalAttempts - 1,
                baseDelay: baseDelay,
                maxDelay: maxDelay,
                totalAttempts: totalAttempts,
            )
            #expect(delay >= maxDelay, "Should be at least the max delay")
            #expect(delay <= maxDelay + maxJitter, "Should not exceed max delay plus 30% jitter")
        }
    }
}
