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

    /// Whether to enable the high-pass filter.
    public let highpassFilter: Bool

    public let typingNoiseDetection: Bool

    /// Selects platform versus WebRTC software echo cancellation.
    public let echoCancellationMode: EchoCancellationMode

    /// Selects platform versus WebRTC software gain control.
    public let autoGainControlMode: AutoGainControlMode

    /// Selects platform versus WebRTC software noise suppression.
    public let noiseSuppressionMode: NoiseSuppressionMode

    /// Selects WebRTC software high-pass filtering behavior.
    public let highpassFilterMode: HighpassFilterMode

    public init(
        echoCancellation: Bool = AudioCaptureOptions.defaultEchoCancellation,
        autoGainControl: Bool = AudioCaptureOptions.defaultAutoGainControl,
        noiseSuppression: Bool = AudioCaptureOptions.defaultNoiseSuppression,
        highpassFilter: Bool = false,
        typingNoiseDetection: Bool = false,
        echoCancellationMode: EchoCancellationMode = .automatic,
        autoGainControlMode: AutoGainControlMode = .automatic,
        noiseSuppressionMode: NoiseSuppressionMode = .automatic,
        highpassFilterMode: HighpassFilterMode = .automatic,
    ) {
        self.echoCancellation = echoCancellation
        self.autoGainControl = autoGainControl
        self.noiseSuppression = noiseSuppression
        self.highpassFilter = highpassFilter
        self.typingNoiseDetection = typingNoiseDetection
        self.echoCancellationMode = echoCancellationMode
        self.autoGainControlMode = autoGainControlMode
        self.noiseSuppressionMode = noiseSuppressionMode
        self.highpassFilterMode = highpassFilterMode
    }

    /// Preserves the Objective-C initializer available before per-effect modes were added.
    @objc(initWithEchoCancellation:autoGainControl:noiseSuppression:highpassFilter:typingNoiseDetection:)
    public convenience init(
        echoCancellation: Bool,
        autoGainControl: Bool,
        noiseSuppression: Bool,
        highpassFilter: Bool,
        typingNoiseDetection: Bool,
    ) {
        self.init(
            echoCancellation: echoCancellation,
            autoGainControl: autoGainControl,
            noiseSuppression: noiseSuppression,
            highpassFilter: highpassFilter,
            typingNoiseDetection: typingNoiseDetection,
            echoCancellationMode: .automatic,
            autoGainControlMode: .automatic,
            noiseSuppressionMode: .automatic,
            highpassFilterMode: .automatic,
        )
    }

    // MARK: - Equatable

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return audioProcessing == other.audioProcessing &&
            typingNoiseDetection == other.typingNoiseDetection
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(audioProcessing)
        hasher.combine(typingNoiseDetection)
        return hasher.finalize()
    }
}

// Internal
extension AudioCaptureOptions {
    /// The per-effect voice-processing configuration as runtime options.
    var audioProcessing: AudioProcessingOptions {
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

    func toFeatures() -> Set<Livekit_AudioTrackFeature> {
        Set([
            echoCancellation ? .tfEchoCancellation : nil,
            noiseSuppression ? .tfNoiseSuppression : nil,
            autoGainControl ? .tfAutoGainControl : nil,
        ].compactMap(\.self))
    }
}
