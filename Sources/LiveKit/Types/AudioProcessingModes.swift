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

/// Selects the echo-cancellation implementation.
public enum EchoCancellationMode: CaseIterable, Hashable, Sendable {
    /// Prefer platform voice processing when available and fall back to WebRTC software processing.
    case automatic
    /// Use platform voice processing only. If platform processing is unavailable, the request is rejected.
    case platform
    /// Force WebRTC software processing and disable the matching platform effect when possible.
    case software
}

/// Selects the automatic-gain-control implementation.
public enum AutoGainControlMode: CaseIterable, Hashable, Sendable {
    /// Prefer platform voice processing when available and fall back to WebRTC software processing.
    case automatic
    /// Use platform voice processing only. If platform processing is unavailable, the request is rejected.
    case platform
    /// Force WebRTC software processing and disable the matching platform effect when possible.
    case software
}

/// Selects the noise-suppression implementation.
public enum NoiseSuppressionMode: CaseIterable, Hashable, Sendable {
    /// Prefer platform voice processing when available and fall back to WebRTC software processing.
    case automatic
    /// Use platform voice processing only. If platform processing is unavailable, the request is rejected.
    case platform
    /// Force WebRTC software processing and disable the matching platform effect when possible.
    case software
}

/// Selects the high-pass-filter implementation.
public enum HighpassFilterMode: CaseIterable, Hashable, Sendable {
    /// Use WebRTC software processing when the filter is enabled.
    case automatic
    /// Force WebRTC software processing.
    case software
}

protocol AudioProcessingModeConvertible: Sendable {
    static var automatic: Self { get }
    static var platformMode: Self? { get }
    static var software: Self { get }

    var rtcType: LKRTCAudioProcessingMode { get }
}

extension AudioProcessingModeConvertible {
    func toRTCType() -> LKRTCAudioProcessingMode {
        rtcType
    }

    func toConstraintValue() -> String {
        switch toRTCType() {
        case .automatic: "auto"
        case .platform: "platform"
        case .software: "software"
        @unknown default: "auto"
        }
    }

    static func fromRTCType(_ mode: LKRTCAudioProcessingMode) -> Self {
        switch mode {
        case .automatic: .automatic
        case .platform: platformMode ?? .automatic
        case .software: .software
        @unknown default: .automatic
        }
    }
}

extension EchoCancellationMode: AudioProcessingModeConvertible {
    static var platformMode: Self? { .platform }

    var rtcType: LKRTCAudioProcessingMode {
        switch self {
        case .automatic: .automatic
        case .platform: .platform
        case .software: .software
        }
    }
}

extension AutoGainControlMode: AudioProcessingModeConvertible {
    static var platformMode: Self? { .platform }

    var rtcType: LKRTCAudioProcessingMode {
        switch self {
        case .automatic: .automatic
        case .platform: .platform
        case .software: .software
        }
    }
}

extension NoiseSuppressionMode: AudioProcessingModeConvertible {
    static var platformMode: Self? { .platform }

    var rtcType: LKRTCAudioProcessingMode {
        switch self {
        case .automatic: .automatic
        case .platform: .platform
        case .software: .software
        }
    }
}

extension HighpassFilterMode: AudioProcessingModeConvertible {
    static var platformMode: Self? { nil }

    var rtcType: LKRTCAudioProcessingMode {
        switch self {
        case .automatic: .automatic
        case .software: .software
        }
    }
}
