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

/// The amount of volume reduction ("ducking") applied to *other audio* while using Apple's voice processing APIs.
///
/// *Other audio* is any playback that is not the voice-chat stream rendered through the voice processing path
/// (for example, media playback in your app outside the SDK, or audio from other apps).
///
/// Use this with ``AudioManager/duckingLevel``.
public enum AudioDuckingLevel: Int {
    /// Matches Apple's historical fixed ducking amount (not the SDK default).
    case `default`
    /// Minimizes ducking (keeps other audio as loud as possible).
    case min
    /// Medium ducking.
    case mid
    /// Maximizes ducking (reduces other audio the most, improving voice intelligibility).
    case max
}

extension AudioDuckingLevel {
    func toRTCType() -> LKRTCAudioDuckingLevel {
        switch self {
        case .default: .default
        case .min: .min
        case .mid: .mid
        case .max: .max
        }
    }
}

extension LKRTCAudioDuckingLevel {
    func toLKType() -> AudioDuckingLevel {
        switch self {
        case .default: return .default
        case .min: return .min
        case .mid: return .mid
        case .max: return .max
        @unknown default: return .default
        }
    }
}
