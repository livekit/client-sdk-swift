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
    // Defaults preserve the historical communication profile. Each component is
    // enabled with `.automatic` mode, which prefers platform processing when
    // available and falls back to WebRTC software processing otherwise.
    public static let defaultEchoCancellation = true
    public static let defaultAutoGainControl = true
    public static let defaultNoiseSuppression = true

    public static let noProcessing = AudioCaptureOptions(
        echoCancellation: false,
        autoGainControl: false,
        noiseSuppression: false,
        highpassFilter: false,
        typingNoiseDetection: false,
    )

    /// Whether to enable echo cancellation.
    public let echoCancellation: Bool

    /// Whether to enable gain control.
    public let autoGainControl: Bool

    /// Whether to enable noise suppression.
    public let noiseSuppression: Bool

    public let highpassFilter: Bool

    public let typingNoiseDetection: Bool

    /// Selects platform versus WebRTC software echo cancellation.
    public let echoCancellationMode: AudioProcessingMode

    /// Selects platform versus WebRTC software gain control.
    public let autoGainControlMode: AudioProcessingMode

    /// Selects platform versus WebRTC software noise suppression.
    public let noiseSuppressionMode: AudioProcessingMode

    /// Selects platform versus WebRTC software high-pass filtering.
    /// No platform HPF exists today, so `platform` is rejected.
    public let highpassFilterMode: AudioProcessingMode

    public init(
        echoCancellation: Bool = AudioCaptureOptions.defaultEchoCancellation,
        autoGainControl: Bool = AudioCaptureOptions.defaultAutoGainControl,
        noiseSuppression: Bool = AudioCaptureOptions.defaultNoiseSuppression,
        highpassFilter: Bool = false,
        typingNoiseDetection: Bool = false,
        echoCancellationMode: AudioProcessingMode = .automatic,
        autoGainControlMode: AudioProcessingMode = .automatic,
        noiseSuppressionMode: AudioProcessingMode = .automatic,
        highpassFilterMode: AudioProcessingMode = .automatic,
    ) {
        self.echoCancellation = echoCancellation
        self.noiseSuppression = noiseSuppression
        self.autoGainControl = autoGainControl
        self.typingNoiseDetection = typingNoiseDetection
        self.highpassFilter = highpassFilter
        self.echoCancellationMode = echoCancellationMode
        self.autoGainControlMode = autoGainControlMode
        self.noiseSuppressionMode = noiseSuppressionMode
        self.highpassFilterMode = highpassFilterMode
    }

    public convenience init(audioProcessingOptions: AudioProcessingOptions,
                            typingNoiseDetection: Bool = false)
    {
        self.init(
            echoCancellation: audioProcessingOptions.echoCancellation,
            autoGainControl: audioProcessingOptions.autoGainControl,
            noiseSuppression: audioProcessingOptions.noiseSuppression,
            highpassFilter: audioProcessingOptions.highpassFilter,
            typingNoiseDetection: typingNoiseDetection,
            echoCancellationMode: audioProcessingOptions.echoCancellationMode,
            autoGainControlMode: audioProcessingOptions.autoGainControlMode,
            noiseSuppressionMode: audioProcessingOptions.noiseSuppressionMode,
            highpassFilterMode: audioProcessingOptions.highpassFilterMode,
        )
    }

    public var audioProcessingOptions: AudioProcessingOptions {
        AudioProcessingOptions(
            echoCancellation: echoCancellation,
            autoGainControl: autoGainControl,
            noiseSuppression: noiseSuppression,
            highpassFilter: highpassFilter,
            echoCancellationMode: echoCancellationMode,
            autoGainControlMode: autoGainControlMode,
            noiseSuppressionMode: noiseSuppressionMode,
            highpassFilterMode: highpassFilterMode,
        )
    }

    // MARK: - Equatable

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return echoCancellation == other.echoCancellation &&
            noiseSuppression == other.noiseSuppression &&
            autoGainControl == other.autoGainControl &&
            typingNoiseDetection == other.typingNoiseDetection &&
            highpassFilter == other.highpassFilter &&
            echoCancellationMode == other.echoCancellationMode &&
            autoGainControlMode == other.autoGainControlMode &&
            noiseSuppressionMode == other.noiseSuppressionMode &&
            highpassFilterMode == other.highpassFilterMode
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(echoCancellation)
        hasher.combine(noiseSuppression)
        hasher.combine(autoGainControl)
        hasher.combine(typingNoiseDetection)
        hasher.combine(highpassFilter)
        hasher.combine(echoCancellationMode)
        hasher.combine(autoGainControlMode)
        hasher.combine(noiseSuppressionMode)
        hasher.combine(highpassFilterMode)
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
