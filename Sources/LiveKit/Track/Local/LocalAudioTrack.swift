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

import AVFAudio
import Combine
import Foundation

internal import LiveKitWebRTC

@objc
public class LocalAudioTrack: Track, LocalTrack, AudioTrack, @unchecked Sendable {
    /// ``AudioCaptureOptions`` used to create this track.
    public let captureOptions: AudioCaptureOptions

    // MARK: - Internal

    struct FrameWatcherState {
        var frameWatcher: AudioFrameWatcher?
    }

    let _frameWatcherState = StateSync(FrameWatcherState())

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

    deinit {
        cleanUpFrameWatcher()
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
        try AudioManager.shared.startLocalRecording()
    }

    override func stopCapture() async throws {
        cleanUpFrameWatcher()
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

// MARK: - Internal frame waiting

extension LocalAudioTrack {
    final class AudioFrameWatcher: AudioRenderer, Loggable {
        private let completer = AsyncCompleter<Void>(label: "Frame watcher", defaultTimeout: 5)

        func wait() async throws {
            try await completer.wait()
        }

        func reset() {
            completer.reset()
        }

        // MARK: - AudioRenderer

        func render(pcmBuffer _: AVAudioPCMBuffer) {
            completer.resume(returning: ())
        }
    }

    func startWaitingForFrames() async throws {
        let frameWatcher = _frameWatcherState.mutate {
            $0.frameWatcher?.reset()
            let watcher = AudioFrameWatcher()
            add(audioRenderer: watcher)
            $0.frameWatcher = watcher
            return watcher
        }

        try await frameWatcher.wait()
        // Detach after wait is complete
        cleanUpFrameWatcher()
    }

    func cleanUpFrameWatcher() {
        _frameWatcherState.mutate {
            if let watcher = $0.frameWatcher {
                watcher.reset()
                remove(audioRenderer: watcher)
                $0.frameWatcher = nil
            }
        }
    }
}
