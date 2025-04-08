/*
 * Copyright 2025 LiveKit
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

class TimeIntervalTests: LKTestCase {
    /// Tests that the reconnection delay computation follows the expected pattern:
    /// - First attempt (index 0): 0 seconds (immediate retry)
    /// - Second attempt (index 1): base delay (typically 300ms)
    /// - Attempts 2-4 (index 2-4): exponential backoff based on attempt number squared
    /// - Remaining attempts (index 5+): max delay (7s) plus random jitter
    func testComputeReconnectDelay() {
        // Test with default base delay (0.3s) with jitter disabled for testing
        XCTAssertEqual(TimeInterval.computeReconnectDelay(forAttempt: 0, addJitter: false), 0, "First attempt should be immediate (0s)")
        XCTAssertEqual(TimeInterval.computeReconnectDelay(forAttempt: 1, addJitter: false), 0.3, "Second attempt should be base delay (0.3s)")

        // Test exponential backoff for attempts 2-4
        // Attempt 2: 2² * 0.3 = 1.2
        XCTAssertEqual(TimeInterval.computeReconnectDelay(forAttempt: 2, addJitter: false), 1.2, "Third attempt should follow exponential backoff")

        // Attempt 3: 3² * 0.3 = 2.7
        // Need to account for floating point precision
        XCTAssertEqual(TimeInterval.computeReconnectDelay(forAttempt: 3, addJitter: false), 2.7, accuracy: 0.0001, "Fourth attempt should follow exponential backoff")

        // Attempt 4: 4² * 0.3 = 4.8
        XCTAssertEqual(TimeInterval.computeReconnectDelay(forAttempt: 4, addJitter: false), 4.8, "Fifth attempt should follow exponential backoff")

        // Test maximum delay cap
        // Attempt 5: 5² * 0.3 = 7.5, but should be capped at 7.0 before jitter
        let fifthAttempt = TimeInterval.computeReconnectDelay(forAttempt: 5, addJitter: false)
        XCTAssertEqual(fifthAttempt, 7.0, "Max retry attempts should use maximum delay")

        // Test with custom base delay (0.5s)
        let customBaseDelay: TimeInterval = 0.5
        XCTAssertEqual(TimeInterval.computeReconnectDelay(forAttempt: 0, baseDelay: customBaseDelay, addJitter: false), 0, "First attempt should be immediate (0s)")
        XCTAssertEqual(TimeInterval.computeReconnectDelay(forAttempt: 1, baseDelay: customBaseDelay, addJitter: false), 0.5, "Second attempt should be custom base delay (0.5s)")
        XCTAssertEqual(TimeInterval.computeReconnectDelay(forAttempt: 2, baseDelay: customBaseDelay, addJitter: false), 2.0, "Third attempt should use custom base delay for calculation")
    }

    /// Tests that jitter is properly applied to attempts #2 and beyond
    func testReconnectDelayJitter() {
        // Test jitter is applied for attempts 2-4 (after our update)
        for attempt in 2 ... 4 {
            let withoutJitter = TimeInterval.computeReconnectDelay(forAttempt: attempt, addJitter: false)
            let withJitter = TimeInterval.computeReconnectDelay(forAttempt: attempt, addJitter: true)

            XCTAssertGreaterThan(withJitter, withoutJitter, "Attempt \(attempt) should have jitter applied")
            XCTAssertLessThanOrEqual(withJitter, withoutJitter + 1.0, "Jitter should not exceed 1.0s")
        }

        // Run multiple times to verify randomness is applied for later attempts
        var attempts: [TimeInterval] = []

        // Create multiple samples with random seeds
        for _ in 0 ..< 10 {
            attempts.append(TimeInterval.computeReconnectDelay(forAttempt: 6))
        }

        // All should be between max delay and max delay + jitter
        for attempt in attempts {
            XCTAssertGreaterThanOrEqual(attempt, 7.0, "Should be at least the max delay")
            XCTAssertLessThanOrEqual(attempt, 8.0, "Should not exceed max delay plus jitter")
        }

        // For randomness check, we can't guarantee uniqueness in a small sample,
        // but we can check the bounds are respected
        let minValue = attempts.min() ?? 0
        let maxValue = attempts.max() ?? 0
        XCTAssertGreaterThanOrEqual(minValue, 7.0, "Min value should be at least max delay")
        XCTAssertLessThanOrEqual(maxValue, 8.0, "Max value should not exceed max delay plus jitter")

        // Compare with non-jittered version
        let nonJitteredValue = TimeInterval.computeReconnectDelay(forAttempt: 6, addJitter: false)
        XCTAssertEqual(nonJitteredValue, 7.0, "Non-jittered value should be exactly max delay")
    }

    /// Tests that maximum retry delay is properly enforced
    func testMaxReconnectDelay() {
        // Create very large base delay
        let largeBaseDelay: TimeInterval = 10.0

        // Attempt 3 with large base delay: 3² * 10 = 90, but should be capped at 7.0
        let delay = TimeInterval.computeReconnectDelay(forAttempt: 3, baseDelay: largeBaseDelay, addJitter: false)
        XCTAssertEqual(delay, 7.0, "Should cap at max retry delay")
    }
}
