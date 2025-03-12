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

import Combine
import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@objc
public class LocalAudioTrack: Track, LocalTrack, AudioTrack {
    /// ``AudioCaptureOptions`` used to create this track.
    let captureOptions: AudioCaptureOptions

    init(name: String,
         source: Track.Source,
         track: LKRTCMediaStreamTrack,
         reportStatistics: Bool,
         captureOptions: AudioCaptureOptions)
    {
        self.captureOptions = captureOptions

        super.init(name: name,
                   kind: .audio,
                   source: source,
                   track: track,
                   reportStatistics: reportStatistics)
    }

    public static func createTrack(name: String = Track.microphoneName,
                                   options: AudioCaptureOptions? = nil,
                                   reportStatistics: Bool = false) -> LocalAudioTrack
    {
        let options = options ?? AudioCaptureOptions()

        let constraints: [String: String] = [
            "googEchoCancellation": options.echoCancellation.toString(),
            "googAutoGainControl": options.autoGainControl.toString(),
            "googNoiseSuppression": options.noiseSuppression.toString(),
            "googTypingNoiseDetection": options.typingNoiseDetection.toString(),
            "googHighpassFilter": options.highpassFilter.toString(),
        ]

        let audioConstraints = DispatchQueue.liveKitWebRTC.sync { LKRTCMediaConstraints(mandatoryConstraints: nil,
                                                                                        optionalConstraints: constraints) }

        let audioSource = RTC.createAudioSource(audioConstraints)
        let rtcTrack = RTC.createAudioTrack(source: audioSource)
        rtcTrack.isEnabled = true

        return LocalAudioTrack(name: name,
                               source: .microphone,
                               track: rtcTrack,
                               reportStatistics: reportStatistics,
                               captureOptions: options)
    }

    public func mute() async throws {
        try await super._mute()
    }

    public func unmute() async throws {
        try await super._unmute()
    }

    // MARK: - Internal

    override func startCapture() async throws {
        // AudioDeviceModule's InitRecording() and StartRecording() automatically get called by WebRTC, but
        // explicitly init & start it early to detect audio engine failures (mic not accessible for some reason, etc.).
        do {
            try AudioManager.shared.startLocalRecording()
        } catch {
            // Make sure internal state is updated to stopped state. (TODO: Remove if ADM reverts state automatically)
            try? AudioManager.shared.stopLocalRecording()
            // Rethrow
            throw error
        }
    }
}

public extension LocalAudioTrack {
    var publishOptions: TrackPublishOptions? { super._state.lastPublishOptions }
    var publishState: Track.PublishState { super._state.publishState }
}

public extension LocalAudioTrack {
    func add(audioRenderer: AudioRenderer) {
        AudioManager.shared.add(localAudioRenderer: audioRenderer)
    }

    func remove(audioRenderer: AudioRenderer) {
        AudioManager.shared.remove(localAudioRenderer: audioRenderer)
    }
}
