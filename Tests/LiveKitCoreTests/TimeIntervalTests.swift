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
    struct DelayCase: Sendable, CustomTestStringConvertible {
        let attempt: Int
        let baseDelay: TimeInterval
        let maxDelay: TimeInterval
        let totalAttempts: Int

        var testDescription: String {
            "attempt \(attempt)/\(totalAttempts) (base=\(baseDelay), max=\(maxDelay))"
        }
    }

    /// Computes the expected easeOutCirc delay for a given attempt.
    static func expectedDelay(for c: DelayCase) -> TimeInterval {
        if c.attempt == c.totalAttempts - 1 {
            return c.maxDelay
        }
        let normalizedIndex = Double(c.attempt) / Double(c.totalAttempts - 1)
        let t = normalizedIndex - 1.0
        let easeOutCircProgress = sqrt(1.0 - t * t)
        return c.baseDelay + easeOutCircProgress * (c.maxDelay - c.baseDelay)
    }

    /// Tests that the reconnection delay computation follows the expected easeOutCirc pattern.
    @Test(arguments: [
        // Default values: baseDelay=0.3, maxDelay=7.0, totalAttempts=10
        DelayCase(attempt: 0, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10),
        DelayCase(attempt: 1, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10),
        DelayCase(attempt: 5, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10),
        DelayCase(attempt: 9, baseDelay: .defaultReconnectDelay, maxDelay: .defaultReconnectMaxDelay, totalAttempts: 10),
        // Custom values
        DelayCase(attempt: 0, baseDelay: 1.0, maxDelay: 5.0, totalAttempts: 5),
        DelayCase(attempt: 1, baseDelay: 1.0, maxDelay: 5.0, totalAttempts: 5),
        DelayCase(attempt: 2, baseDelay: 1.0, maxDelay: 5.0, totalAttempts: 5),
        DelayCase(attempt: 4, baseDelay: 1.0, maxDelay: 5.0, totalAttempts: 5),
        // Inverted (baseDelay > maxDelay)
        DelayCase(attempt: 0, baseDelay: 10.0, maxDelay: 5.0, totalAttempts: 5),
        DelayCase(attempt: 1, baseDelay: 10.0, maxDelay: 5.0, totalAttempts: 5),
        DelayCase(attempt: 2, baseDelay: 10.0, maxDelay: 5.0, totalAttempts: 5),
        DelayCase(attempt: 4, baseDelay: 10.0, maxDelay: 5.0, totalAttempts: 5),
    ])
    func computeReconnectDelay(_ c: DelayCase) {
        let actual = TimeInterval.computeReconnectDelay(
            forAttempt: c.attempt,
            baseDelay: c.baseDelay,
            maxDelay: c.maxDelay,
            totalAttempts: c.totalAttempts,
            addJitter: false
        )
        let expected = Self.expectedDelay(for: c)

        if c.attempt == c.totalAttempts - 1 {
            #expect(actual == expected, "Last attempt should be exactly maxDelay")
        } else {
            #expect(abs(actual - expected) <= 0.001, "Attempt \(c.attempt) should follow easeOutCirc curve")
        }
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
            addJitter: false
        )

        let withJitter = TimeInterval.computeReconnectDelay(
            forAttempt: attempt,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            totalAttempts: totalAttempts,
            addJitter: true
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
                totalAttempts: totalAttempts
            )
            #expect(delay >= maxDelay, "Should be at least the max delay")
            #expect(delay <= maxDelay + maxJitter, "Should not exceed max delay plus 30% jitter")
        }
    }
}
