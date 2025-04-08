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
    static let defaultReconnectAttemptDelay: Self = 0.3 // 300ms to match JS SDK
    // reconnect delays for the first few attempts, followed by maxRetryDelay
    static let reconnectDelayMaxRetry: Self = 7 // maximum retry delay in seconds
    static let reconnectDelayJitter: Self = 1.0 // 1 second jitter for later retries

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

    /// Computes a retry delay based on the JS SDK-compatible reconnection algorithm
    /// - Parameter attempt: The current retry attempt (0-based index)
    /// - Parameter baseDelay: The base delay for calculations (default: 0.3s)
    /// - Parameter addJitter: Whether to add random jitter to delay for attempts #2+ (default: true)
    /// - Returns: The delay in seconds to wait before the next retry attempt
    @Sendable
    static func computeReconnectDelay(forAttempt attempt: Int,
                                      baseDelay: TimeInterval = defaultReconnectAttemptDelay,
                                      addJitter: Bool = true) -> TimeInterval
    {
        if attempt < 2 {
            // First two attempts use fixed delay (0ms, 300ms)
            return attempt == 0 ? 0 : baseDelay
        } else if attempt < 5 {
            // Next 3 attempts use exponential backoff with optional jitter
            let exponent = Double(attempt)
            let calculatedDelay = min(exponent * exponent * baseDelay, reconnectDelayMaxRetry)

            // Add jitter for attempts #2+ to match JS SDK
            if addJitter {
                return calculatedDelay + (Double.random(in: 0 ..< 1.0) * reconnectDelayJitter)
            }
            return calculatedDelay
        } else {
            // Remaining attempts use max delay with optional jitter
            if addJitter {
                return reconnectDelayMaxRetry + (Double.random(in: 0 ..< 1.0) * reconnectDelayJitter)
            } else {
                return reconnectDelayMaxRetry
            }
        }
    }
}

extension TimeInterval {
    var toDispatchTimeInterval: DispatchTimeInterval {
        .milliseconds(Int(self * 1000))
    }
}
