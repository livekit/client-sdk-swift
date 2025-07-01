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

internal import LiveKitWebRTC

@objc
public final class AudioCaptureOptions: NSObject, CaptureOptions, Sendable {
    // Default values for platform
    #if targetEnvironment(simulator)
    // On simulator, Apple's Voice-Processing I/O is not available. Use WebRTC's voice processing instead.
    public static let defaultEchoCancellation = true
    public static let defaultAutoGainControl = true
    public static let defaultNoiseSuppression = true
    #else
    // On devices, use Apple's Voice-Processing I/O by default instead of WebRTC's voice processing.
    // See ``AudioManager/isVoiceProcessingEnabled`` for details.
    public static let defaultEchoCancellation = false
    public static let defaultAutoGainControl = false
    public static let defaultNoiseSuppression = false
    #endif

    public static let noProcessing = AudioCaptureOptions(
        echoCancellation: false,
        autoGainControl: false,
        noiseSuppression: false,
        highpassFilter: false,
        typingNoiseDetection: false
    )

    /// Whether to enable software (WebRTC's) echo cancellation.
    /// By default, Apple's voice processing is already enabled.
    /// See ``AudioManager/isVoiceProcessingBypassed`` for details.
    @objc
    public let echoCancellation: Bool

    /// Whether to enable software (WebRTC's) gain control.
    /// By default, Apple's gain control is already enabled.
    /// See ``AudioManager/isVoiceProcessingAGCEnabled`` for details.
    @objc
    public let autoGainControl: Bool

    @objc
    public let noiseSuppression: Bool

    @objc
    public let highpassFilter: Bool

    @objc
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
        ].compactMap { $0 })
    }
}
