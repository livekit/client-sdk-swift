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
    // Defaults are `true` on all platforms. These options affect WebRTC's
    // software APM. In the default audio processing mode, Apple's VPIO handles
    // AEC/AGC/NS on iOS device and macOS, so software APM is off. Use
    // `AudioManager.shared.setAudioProcessingMode(.software)` to explicitly
    // select WebRTC software processing on supported AudioEngineDevice builds.
    //
    // Platform behavior:
    // - iOS device or macOS with `.automatic`: VPIO is active. Software APM is
    //   off. These flags are still reported to the server as audio track
    //   features for telemetry.
    // - iOS device or macOS with `.software`: Software APM is active and these
    //   flags are respected.
    // - iOS Simulator: VPIO is not reliably available. Software APM is used and
    //   these flags are respected.
    //
    // To control the processing backend, see
    // ``AudioManager/setAudioProcessingMode(_:)``.
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
    /// Takes effect when WebRTC software processing is active.
    /// See ``AudioManager/setAudioProcessingMode(_:)`` for backend selection.
    public let echoCancellation: Bool

    /// Whether to enable software (WebRTC's) gain control.
    /// Takes effect when WebRTC software processing is active.
    /// See ``AudioManager/setAudioProcessingMode(_:)`` for backend selection.
    public let autoGainControl: Bool

    /// Whether to enable software (WebRTC's) noise suppression.
    /// Takes effect when WebRTC software processing is active.
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
