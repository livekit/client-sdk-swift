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

internal import LiveKitWebRTC

@objcMembers
public final class AudioCaptureOptions: NSObject, CaptureOptions, Sendable {
    // Defaults are `true` on all platforms. In practice these options only affect
    // software (WebRTC) APM on iOS Simulator. On iOS device or macOS, Apple's VPIO
    // handles AEC/AGC/NS and software APM is always off regardless of these flags.
    //
    // Platform behavior:
    // - iOS device or macOS: VPIO is active. Software APM is always off. These
    //   flags are effectively ignored for runtime processing, but still reported
    //   to the server as audio track features for telemetry.
    // - iOS Simulator: VPIO is not reliably available. Software APM is used and
    //   these flags are respected.
    //
    // To control VPIO on device, see ``AudioManager/isVoiceProcessingEnabled``,
    // ``AudioManager/isVoiceProcessingBypassed``, and
    // ``AudioManager/isVoiceProcessingAGCEnabled``.
    public static let defaultEchoCancellation = true
    public static let defaultAutoGainControl = true
    public static let defaultNoiseSuppression = true

    public static let noProcessing = AudioCaptureOptions(
        echoCancellation: false,
        autoGainControl: false,
        noiseSuppression: false,
        highpassFilter: false,
        typingNoiseDetection: false
    )

    /// Whether to enable software (WebRTC's) echo cancellation.
    /// Only takes effect on iOS Simulator. On iOS device or macOS, Apple's VPIO
    /// handles AEC and this flag is ignored for runtime processing.
    /// See ``AudioManager/isVoiceProcessingBypassed`` for device-side VPIO controls.
    public let echoCancellation: Bool

    /// Whether to enable software (WebRTC's) gain control.
    /// Only takes effect on iOS Simulator. On iOS device or macOS, Apple's VPIO
    /// handles AGC and this flag is ignored for runtime processing.
    /// See ``AudioManager/isVoiceProcessingAGCEnabled`` for device-side VPIO controls.
    public let autoGainControl: Bool

    /// Whether to enable software (WebRTC's) noise suppression.
    /// Only takes effect on iOS Simulator. On iOS device or macOS, Apple's VPIO
    /// handles NS and this flag is ignored for runtime processing.
    public let noiseSuppression: Bool

    public let highpassFilter: Bool

    public let typingNoiseDetection: Bool

    public init(
        echoCancellation: Bool = AudioCaptureOptions.defaultEchoCancellation,
        autoGainControl: Bool = AudioCaptureOptions.defaultAutoGainControl,
        noiseSuppression: Bool = AudioCaptureOptions.defaultNoiseSuppression,
        highpassFilter: Bool = false,
        typingNoiseDetection: Bool = false
    ) {
        self.echoCancellation = echoCancellation
        self.noiseSuppression = noiseSuppression
        self.autoGainControl = autoGainControl
        self.typingNoiseDetection = typingNoiseDetection
        self.highpassFilter = highpassFilter
    }

    // MARK: - Equatable

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return echoCancellation == other.echoCancellation &&
            noiseSuppression == other.noiseSuppression &&
            autoGainControl == other.autoGainControl &&
            typingNoiseDetection == other.typingNoiseDetection &&
            highpassFilter == other.highpassFilter
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(echoCancellation)
        hasher.combine(noiseSuppression)
        hasher.combine(autoGainControl)
        hasher.combine(typingNoiseDetection)
        hasher.combine(highpassFilter)
        return hasher.finalize()
    }
}

// Internal
extension AudioCaptureOptions {
    func toFeatures() -> Set<Livekit_AudioTrackFeature> {
        Set([
            echoCancellation ? .tfEchoCancellation : nil,
            noiseSuppression ? .tfNoiseSuppression : nil,
            autoGainControl ? .tfAutoGainControl : nil,
        ].compactMap(\.self))
    }
}
