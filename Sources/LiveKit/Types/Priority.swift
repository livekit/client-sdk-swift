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

internal import LiveKitWebRTC

/// Priority levels for RTP encoding parameters.
///
/// `bitratePriority` controls WebRTC internal bandwidth allocation between streams.
/// When not set, WebRTC uses its default value equivalent to `.low` (1.0x).
///
/// `networkPriority` controls DSCP marking for network-level QoS.
/// Requires `ConnectOptions.isDscpEnabled` to be true.
@objc
public enum Priority: Int, Sendable {
    case veryLow
    case low
    case medium
    case high
}

extension Priority {
    /// Converts to the native RTCPriority enum used for networkPriority.
    func toRTCPriority() -> LKRTCPriority {
        switch self {
        case .veryLow: .veryLow
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    /// Converts to bitratePriority double value.
    /// - veryLow: 0.5x
    /// - low: 1.0x (default)
    /// - medium: 2.0x
    /// - high: 4.0x
    func toBitratePriority() -> Double {
        switch self {
        case .veryLow: 0.5
        case .low: 1.0
        case .medium: 2.0
        case .high: 4.0
        }
    }
}
