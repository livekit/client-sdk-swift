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

@objc
public enum DegradationPreference: Int, Sendable {
    /// The SDK will decide which preference is suitable or will use WebRTC's default implementation.
    case auto
    @available(*, deprecated, renamed: "maintainFramerateAndResolution")
    case disabled
    /// Prefer to maintain FPS rather than resolution.
    case maintainFramerate
    /// Prefer to maintain resolution rather than FPS.
    case maintainResolution
    case balanced
    /// Prefer to maintain both FPS and resolution.
    case maintainFramerateAndResolution
}

extension DegradationPreference {
    func toRTCType() -> LKRTCDegradationPreference? {
        switch self {
        case .auto: nil
        case .disabled: .maintainFramerateAndResolution
        case .maintainFramerate: .maintainFramerate
        case .maintainResolution: .maintainResolution
        case .maintainFramerateAndResolution: .maintainFramerateAndResolution
        case .balanced: .balanced
        }
    }

    /// Resolves this preference for a track published under `source`.
    ///
    /// ``DegradationPreference/auto`` picks a default based on the source:
    /// - Camera: ``DegradationPreference/maintainFramerate`` (smoother video for real-time communication)
    /// - Screen share: ``DegradationPreference/maintainResolution`` (clarity is critical for reading text/UI)
    /// - Other/unknown: ``DegradationPreference/balanced``
    ///
    /// Any other source means the application declined to declare a motion-vs-detail intent,
    /// so this falls back to balanced, the preference the WebRTC spec mandates as the default.
    func resolve(for source: Track.Source) -> LKRTCDegradationPreference {
        if let explicit = toRTCType() {
            return explicit
        }
        switch source {
        case .camera: return .maintainFramerate
        case .screenShareVideo: return .maintainResolution
        default: return .balanced
        }
    }
}
