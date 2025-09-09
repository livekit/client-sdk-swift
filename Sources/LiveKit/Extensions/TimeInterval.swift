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

import Foundation

/// Default timeout `TimeInterval`s used throughout the SDK.
public extension TimeInterval {
    // reconnection settings
    static let defaultReconnectDelay: Self = 0.3 // 300ms to match JS SDK
    // reconnect delays for the first few attempts, followed by maxRetryDelay
    static let defaultReconnectMaxDelay: Self = 7 // maximum retry delay in seconds
    static let defaultReconnectDelayJitter: Self = 1.0 // 1 second jitter for later retries

    // the following 3 timeouts are used for a typical connect sequence
    static let defaultSocketConnect: Self = 10
    // used for validation mode
    static let defaultHTTPConnect: Self = 5

    static let defaultJoinResponse: Self = 7
    static let defaultTransportState: Self = 10
    static let defaultPublisherDataChannelOpen: Self = 7
    static let resolveSid: Self = 7 + 5 // Join response + 5
    static let defaultPublish: Self = 10
    static let defaultCaptureStart: Self = 10

    static let defaultParticipantActiveTimeout: Self = 10

    /// Computes a retry delay based on an "easeOutCirc" curve between baseDelay and maxDelay.
    ///
    /// The easeOutCirc curve provides a dramatic early acceleration followed by a gentler approach to the maximum,
    /// resulting in larger delays early in the reconnection sequence to reduce unnecessary network traffic.
    ///
    /// Example values for 10 reconnection attempts with baseDelay=0.3s and maxDelay=7s:
    /// - Attempt 0: ~0.85s (already 12% of the way to max)
    /// - Attempt 1: ~2.2s (30% of the way to max)
    /// - Attempt 2: ~3.4s (45% of the way to max)
    /// - Attempt 5: ~5.9s (82% of the way to max)
    /// - Attempt 9: 7.0s (exactly maxDelay)
    ///
    /// - Parameter attempt: The current retry attempt (0-based index)
    /// - Parameter baseDelay: The minimum delay for the curve's starting point (default: 0.3s)
    /// - Parameter maxDelay: The maximum delay for the last retry attempt (default: 7s)
    /// - Parameter totalAttempts: The total number of attempts that will be made (default: 10)
    /// - Parameter addJitter: Whether to add random jitter to the delay (default: true)
    /// - Returns: The delay in seconds to wait before the next retry attempt
    @Sendable
    static func computeReconnectDelay(forAttempt attempt: Int,
                                      baseDelay: TimeInterval,
                                      maxDelay: TimeInterval,
                                      totalAttempts: Int,
                                      addJitter: Bool = true) -> TimeInterval
    {
        // Last attempt should use maxDelay exactly
        if attempt >= totalAttempts - 1 {
            return maxDelay
        }

        // Make sure we have a valid value for total attempts
        let validTotalAttempts = max(2, totalAttempts) // Need at least 2 attempts

        // Apply easeOutCirc curve to all attempts (0 through n-2)
        // We normalize the attempt index to a 0-1 range
        let normalizedIndex = Double(attempt) / Double(validTotalAttempts - 1)

        // Apply easeOutCirc curve: sqrt(1 - pow(x - 1, 2))
        // This creates a very dramatic early acceleration with a smooth approach to the maximum
        let t = normalizedIndex - 1.0
        let easeOutCircProgress = sqrt(1.0 - t * t)

        // Calculate the delay by applying the easeOutCirc curve between baseDelay and maxDelay
        let calculatedDelay = baseDelay + easeOutCircProgress * (maxDelay - baseDelay)

        // Add jitter if requested (up to 10% of the calculated delay)
        if addJitter {
            return calculatedDelay + (Double.random(in: 0 ..< 0.1) * calculatedDelay)
        } else {
            return calculatedDelay
        }
    }
}

extension TimeInterval {
    var toDispatchTimeInterval: DispatchTimeInterval {
        .milliseconds(Int(self * 1000))
    }
}
