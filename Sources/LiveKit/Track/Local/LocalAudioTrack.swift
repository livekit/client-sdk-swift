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

internal import LiveKitFFI
internal import LiveKitWebRTC
import AVFAudio
import Combine
import Foundation

@objcMembers
public class LocalAudioTrack: Track, LocalTrackProtocol, AudioTrackProtocol, @unchecked Sendable {
    /// ``AudioCaptureOptions`` used to create this track.
    public let captureOptions: AudioCaptureOptions

    // MARK: - Internal

    struct FrameWatcherState {
        var frameWatcher: AudioFrameWatcher?
    }

    let _frameWatcherState = StateSync(FrameWatcherState())

    init(name: String,
         source: Track.Source,
         track: RTCMediaTrack?,
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
        if let watcher = _frameWatcherState.frameWatcher {
            remove(audioRenderer: watcher)
        }
    }

    @available(*, deprecated, message: "Blocks the calling thread until WebRTC's factory responds; use the async variant instead.")
    public static func createTrack(name: String = Track.microphoneName,
                                   options: AudioCaptureOptions? = nil,
                                   reportStatistics: Bool = false) -> LocalAudioTrack
    {
        _createTrack(name: name, options: options, reportStatistics: reportStatistics)
    }

    /// Creates a microphone track on the RTC executor: the calling task suspends instead of
    /// blocking its thread on WebRTC's factory.
    public static func createTrack(name: String = Track.microphoneName,
                                   options: AudioCaptureOptions? = nil,
                                   reportStatistics: Bool = false) async -> LocalAudioTrack
    {
        await RTC.run { _createTrack(name: name, options: options, reportStatistics: reportStatistics) }
    }

    static func _createTrack(name: String,
                             options: AudioCaptureOptions?,
                             reportStatistics: Bool) -> LocalAudioTrack
    {
        LocalAudioTrack(name: name, source: .microphone, track: nil,
                        reportStatistics: reportStatistics, captureOptions: options ?? AudioCaptureOptions())
    }

    let nativeAudio = StateSync<NativeLocalAudioTrack?>(nil)

    public func mute() async throws {
        try await super._mute()
    }

    public func unmute() async throws {
        try await super._unmute()
    }

    /// Updates this local track's voice processing options without restarting capture.
    ///
    /// If this track is already published, WebRTC reapplies the updated options through
    /// the active sender. Effective APM configuration is shared by the WebRTC voice engine,
    /// so conflicting updates from multiple local audio tracks are last-writer-wins.
    ///
    /// - Returns: Whether the options were applied immediately or stored for reapplication.
    /// - Throws: ``AudioProcessingOptionsError`` when the options cannot be applied.
    /// - Note: Blocks the calling thread until WebRTC's signaling thread applies the options.
    @discardableResult
    public func setAudioProcessingOptions(_: AudioProcessingOptions) throws -> AudioProcessingOptionsResult {
        throw LiveKitError(.audioEngine, message: "Native audio processing and AVAudioEngine configuration are not exported by this artifact")
    }

    // MARK: - Internal

    override func startCapture() async throws {
        guard nativeAudio.copy() != nil else {
            throw LiveKitError(.invalidState, message: "Native audio capture requires a connected room publication")
        }
    }

    override func stopCapture() async throws {
        cleanUpFrameWatcher()
    }
}

extension LocalAudioTrack {
    /// Everything the server is told about this track: capture processing, publish options and Krisp.
    func features(publishOptions: AudioPublishOptions?) -> Set<Livekit_AudioTrackFeature> {
        var features = captureOptions.toFeatures()
        features.formUnion(publishOptions?.toFeatures() ?? [])
        if AudioManager.shared.capturePostProcessingDelegate?.audioProcessingName == kLiveKitKrispAudioProcessorName {
            features.insert(.tfEnhancedNoiseCancellation)
        }
        return features
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
