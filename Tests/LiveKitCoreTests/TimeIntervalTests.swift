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

class TimeIntervalTests: LKTestCase {
    /// Tests that the reconnection delay computation follows the expected easeOutCirc pattern:
    /// - All attempts (0 through n-2): easeOutCirc curve from baseDelay to maxDelay for dramatic early growth
    /// - Last attempt (n-1): exactly maxDelay
    func testComputeReconnectDelay() { // swiftlint:disable:this function_body_length
        // Default values: baseDelay=0.3, maxDelay=7.0, totalAttempts=10
        let totalAttempts = 10
        let baseDelay = TimeInterval.defaultReconnectDelay // 0.3
        let maxDelay = TimeInterval.defaultReconnectMaxDelay // 7.0

        // First attempt (attempt=0) should follow easeOutCirc curve
        let firstAttempt = 0
        let firstNormalizedIndex = Double(firstAttempt) / Double(totalAttempts - 1)
        let firstT = firstNormalizedIndex - 1.0
        let firstEaseOutCircProgress = sqrt(1.0 - firstT * firstT)
        let expectedFirstDelay = baseDelay + firstEaseOutCircProgress * (maxDelay - baseDelay)

        XCTAssertEqual(
            TimeInterval.computeReconnectDelay(
                forAttempt: firstAttempt,
                baseDelay: baseDelay,
                maxDelay: maxDelay,
                totalAttempts: totalAttempts,
                addJitter: false
            ),
            expectedFirstDelay,
            accuracy: 0.001,
            "First attempt should follow easeOutCirc curve"
        )

        // Second attempt (attempt=1) should follow easeOutCirc curve
        let secondAttempt = 1
        let secondNormalizedIndex = Double(secondAttempt) / Double(totalAttempts - 1)
        let secondT = secondNormalizedIndex - 1.0
        let secondEaseOutCircProgress = sqrt(1.0 - secondT * secondT)
        let expectedSecondDelay = baseDelay + secondEaseOutCircProgress * (maxDelay - baseDelay)

        XCTAssertEqual(
            TimeInterval.computeReconnectDelay(
                forAttempt: secondAttempt,
                baseDelay: baseDelay,
                maxDelay: maxDelay,
                totalAttempts: totalAttempts,
                addJitter: false
            ),
            expectedSecondDelay,
            accuracy: 0.001,
            "Second attempt should follow easeOutCirc curve"
        )

        // Test a middle attempt (attempt 5, index 4)
        // For an easeOutCirc curve, the formula is:
        // baseDelay + sqrt(1 - pow((attempt/(totalAttempts-1) - 1), 2)) * (maxDelay - baseDelay)
        let midAttempt = 5
        let normalizedIndex = Double(midAttempt) / Double(totalAttempts - 1)
        let t = normalizedIndex - 1.0
        let easeOutCircProgress = sqrt(1.0 - t * t)
        let expectedMiddleDelay = baseDelay + easeOutCircProgress * (maxDelay - baseDelay)

        XCTAssertEqual(
            TimeInterval.computeReconnectDelay(
                forAttempt: midAttempt,
                baseDelay: baseDelay,
                maxDelay: maxDelay,
                totalAttempts: totalAttempts,
                addJitter: false
            ),
            expectedMiddleDelay,
            accuracy: 0.001,
            "Middle attempt should follow easeOutCirc scale"
        )

        // Last attempt should be exactly maxDelay
        XCTAssertEqual(
            TimeInterval.computeReconnectDelay(
                forAttempt: totalAttempts - 1,
                baseDelay: baseDelay,
                maxDelay: maxDelay,
                totalAttempts: totalAttempts,
                addJitter: false
            ),
            maxDelay,
            "Last attempt should be exactly max delay"
        )

        // Test with custom values
        let customBaseDelay: TimeInterval = 1.0
        let customMaxDelay: TimeInterval = 5.0
        let customTotalAttempts = 5

        // First attempt should follow easeOutCirc curve with custom values
        let customFirstAttempt = 0
        let customFirstNormalizedIndex = Double(customFirstAttempt) / Double(customTotalAttempts - 1)
        let customFirstT = customFirstNormalizedIndex - 1.0
        let customFirstEaseOutCircProgress = sqrt(1.0 - customFirstT * customFirstT)
        let expectedCustomFirstDelay = customBaseDelay + customFirstEaseOutCircProgress * (customMaxDelay - customBaseDelay)

        XCTAssertEqual(
            TimeInterval.computeReconnectDelay(
                forAttempt: customFirstAttempt,
                baseDelay: customBaseDelay,
                maxDelay: customMaxDelay,
                totalAttempts: customTotalAttempts,
                addJitter: false
            ),
            expectedCustomFirstDelay,
            accuracy: 0.001,
            "First attempt should follow easeOutCirc curve with custom values"
        )

        // Second attempt should follow easeOutCirc curve
        let customSecondAttempt = 1
        let customSecondNormalizedIndex = Double(customSecondAttempt) / Double(customTotalAttempts - 1)
        let customSecondT = customSecondNormalizedIndex - 1.0
        let customSecondEaseOutCircProgress = sqrt(1.0 - customSecondT * customSecondT)
        let expectedCustomSecondDelay = customBaseDelay + customSecondEaseOutCircProgress * (customMaxDelay - customBaseDelay)

        XCTAssertEqual(
            TimeInterval.computeReconnectDelay(
                forAttempt: customSecondAttempt,
                baseDelay: customBaseDelay,
                maxDelay: customMaxDelay,
                totalAttempts: customTotalAttempts,
                addJitter: false
            ),
            expectedCustomSecondDelay,
            accuracy: 0.001,
            "Second attempt should follow easeOutCirc curve with custom values"
        )

        // Test a middle custom attempt with easeOutCirc formula
        let customMidAttempt = 2
        let customNormalizedIndex = Double(customMidAttempt) / Double(customTotalAttempts - 1)
        let customT = customNormalizedIndex - 1.0
        let customEaseOutCircProgress = sqrt(1.0 - customT * customT)
        let expectedCustomMiddleDelay = customBaseDelay + customEaseOutCircProgress * (customMaxDelay - customBaseDelay)

        XCTAssertEqual(
            TimeInterval.computeReconnectDelay(
                forAttempt: customMidAttempt,
                baseDelay: customBaseDelay,
                maxDelay: customMaxDelay,
                totalAttempts: customTotalAttempts,
                addJitter: false
            ),
            expectedCustomMiddleDelay,
            accuracy: 0.001,
            "Custom middle attempt should follow easeOutCirc scale"
        )

        // Last attempt should be max delay
        XCTAssertEqual(
            TimeInterval.computeReconnectDelay(
                forAttempt: customTotalAttempts - 1,
                baseDelay: customBaseDelay,
                maxDelay: customMaxDelay,
                totalAttempts: customTotalAttempts,
                addJitter: false
            ),
            customMaxDelay,
            "Last attempt should be max delay"
        )
    }

    /// Tests that jitter is properly applied to attempts
    func testReconnectDelayJitter() { // swiftlint:disable:this function_body_length
        // Set up test values
        let baseDelay = TimeInterval.defaultReconnectDelay
        let maxDelay = TimeInterval.defaultReconnectMaxDelay
        let totalAttempts = 10

        // Test jitter is applied for all non-zero attempts
        for attempt in 1 ... 5 {
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

            XCTAssertGreaterThan(withJitter, withoutJitter, "Attempt \(attempt) should have jitter applied")

            // Our jitter is now 30% of the calculated delay
            let maxExpectedJitter = withoutJitter * 0.3
            XCTAssertLessThanOrEqual(
                withJitter,
                withoutJitter + maxExpectedJitter,
                "Jitter should not exceed 30% of the delay"
            )
        }

        // Run multiple times to verify randomness is applied for the last attempt
        var attempts: [TimeInterval] = []

        // Create multiple samples with random seeds
        for _ in 0 ..< 10 {
            attempts.append(
                TimeInterval.computeReconnectDelay(
                    forAttempt: totalAttempts - 1,
                    baseDelay: baseDelay,
                    maxDelay: maxDelay,
                    totalAttempts: totalAttempts
                )
            )
        }

        // All should be between max delay and max delay + 30% jitter
        let maxJitter = maxDelay * 0.3
        for attempt in attempts {
            XCTAssertGreaterThanOrEqual(attempt, maxDelay, "Should be at least the max delay")
            XCTAssertLessThanOrEqual(attempt, maxDelay + maxJitter, "Should not exceed max delay plus 30% jitter")
        }

        // For randomness check, we can't guarantee uniqueness in a small sample,
        // but we can check the bounds are respected
        let minValue = attempts.min() ?? 0
        let maxValue = attempts.max() ?? 0
        XCTAssertGreaterThanOrEqual(minValue, maxDelay, "Min value should be at least max delay")
        XCTAssertLessThanOrEqual(maxValue, maxDelay + maxJitter, "Max value should not exceed max delay plus 30% jitter")

        // Compare with non-jittered version
        let nonJitteredValue = TimeInterval.computeReconnectDelay(
            forAttempt: totalAttempts - 1,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            totalAttempts: totalAttempts,
            addJitter: false
        )

        XCTAssertEqual(nonJitteredValue, maxDelay, "Non-jittered value should be exactly max delay")
    }

    /// Tests that baseDelay and maxDelay relationship works correctly with easeOutCirc scaling
    func testMaxReconnectDelay() {
        // Test with custom baseDelay > maxDelay
        let largeBaseDelay: TimeInterval = 10.0
        let smallMaxDelay: TimeInterval = 5.0
        let totalAttempts = 5

        // For attempt 0, should follow easeOutCirc curve
        let firstNormalizedIndex = Double(0) / Double(totalAttempts - 1)
        let firstT = firstNormalizedIndex - 1.0
        let firstEaseOutCircProgress = sqrt(1.0 - firstT * firstT)
        let expectedFirstDelay = largeBaseDelay + firstEaseOutCircProgress * (smallMaxDelay - largeBaseDelay)

        let delay0 = TimeInterval.computeReconnectDelay(
            forAttempt: 0,
            baseDelay: largeBaseDelay,
            maxDelay: smallMaxDelay,
            totalAttempts: totalAttempts,
            addJitter: false
        )

        XCTAssertEqual(delay0, expectedFirstDelay, accuracy: 0.001, "First attempt should follow easeOutCirc curve")

        // For attempt 1, should follow easeOutCirc curve
        let secondNormalizedIndex = Double(1) / Double(totalAttempts - 1)
        let secondT = secondNormalizedIndex - 1.0
        let secondEaseOutCircProgress = sqrt(1.0 - secondT * secondT)
        let expectedSecondDelay = largeBaseDelay + secondEaseOutCircProgress * (smallMaxDelay - largeBaseDelay)

        let delay1 = TimeInterval.computeReconnectDelay(
            forAttempt: 1,
            baseDelay: largeBaseDelay,
            maxDelay: smallMaxDelay,
            totalAttempts: totalAttempts,
            addJitter: false
        )

        XCTAssertEqual(delay1, expectedSecondDelay, accuracy: 0.001, "Second attempt should follow easeOutCirc curve")

        // For the last attempt, should be maxDelay
        let delay4 = TimeInterval.computeReconnectDelay(
            forAttempt: totalAttempts - 1,
            baseDelay: largeBaseDelay,
            maxDelay: smallMaxDelay,
            totalAttempts: totalAttempts,
            addJitter: false
        )

        XCTAssertEqual(delay4, smallMaxDelay, "Last attempt should be maxDelay")

        // For a middle attempt (2), the easeOutCirc formula applies even when scaling down
        let midAttempt = 2
        let normalizedIndex = Double(midAttempt) / Double(totalAttempts - 1)
        let t = normalizedIndex - 1.0
        let easeOutCircProgress = sqrt(1.0 - t * t)
        let expectedMiddleDelay = largeBaseDelay + easeOutCircProgress * (smallMaxDelay - largeBaseDelay)

        let delay2 = TimeInterval.computeReconnectDelay(
            forAttempt: midAttempt,
            baseDelay: largeBaseDelay,
            maxDelay: smallMaxDelay,
            totalAttempts: totalAttempts,
            addJitter: false
        )

        XCTAssertEqual(delay2, expectedMiddleDelay, accuracy: 0.001, "Middle attempt should scale properly with easeOutCirc curve")
    }
}
