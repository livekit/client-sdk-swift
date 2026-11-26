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
    // Matches client-sdk-js (`peerConnectionTimeout`) and client-sdk-rust
    // (`ICE_CONNECT_TIMEOUT`); client-sdk-android uses 20s.
    static let defaultPublisherDataChannelOpen: Self = 15
    static let resolveSid: Self = 7 + 5 // Join response + 5
    static let defaultPublish: Self = 10
    // Matches client-sdk-rust (`DATA_BLOB_REQUEST_TIMEOUT`).
    static let defaultDataBlobRequest: Self = 5
    static let defaultCaptureStart: Self = 10
    // Waits on a person choosing content in the system picker, not on the network.
    static let defaultScreenSharePicker: Self = 60

    static let defaultParticipantActiveTimeout: Self = 10

    /// Computes a retry delay that grows with the square of the attempt number, capped at maxDelay.
    ///
    /// The first retries follow quickly, so a short outage recovers soon. Later retries are spaced out.
    ///
    /// Example values for 10 reconnection attempts with baseDelay=0.3s and maxDelay=7s, before jitter:
    /// - Attempt 0: 0.3s
    /// - Attempt 1: 1.2s
    /// - Attempt 2: 2.7s
    /// - Attempt 3: 4.8s
    /// - Attempt 4 and later: 7.0s (maxDelay)
    ///
    /// The SDK waits this delay after a failed attempt, so it only passes attempts 0 through totalAttempts - 2.
    /// A negative baseDelay or maxDelay counts as zero. Jitter never takes the delay above a maxDelay of zero or more.
    ///
    /// - Parameter attempt: The current retry attempt (0-based index)
    /// - Parameter baseDelay: The delay for attempt 0 (default: 0.3s)
    /// - Parameter maxDelay: The maximum delay, zero if negative, also returned without jitter from attempt totalAttempts - 1 on (default: 7s)
    /// - Parameter totalAttempts: The total number of attempts that will be made (default: 10)
    /// - Parameter addJitter: Whether to take a random part of up to 10% off the delay (default: true)
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
            return Swift.max(0, maxDelay)
        }

        let step = Double(attempt + 1)
        let calculatedDelay = Swift.max(0, Swift.min(maxDelay, baseDelay * step * step))

        // Jitter takes up to 10% off, so the delay stays at or below maxDelay
        return addJitter ? calculatedDelay * Double.random(in: 0.9 ... 1) : calculatedDelay
    }
}

extension TimeInterval {
    var toDispatchTimeInterval: DispatchTimeInterval {
        .milliseconds(Int(self * 1000))
    }
}
