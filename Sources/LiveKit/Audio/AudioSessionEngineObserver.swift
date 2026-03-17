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

#if os(iOS) || os(visionOS) || os(tvOS)

import AVFoundation

internal import LiveKitWebRTC

/// An ``AudioEngineObserver`` that configures the `AVAudioSession` based on the state of the audio engine.
public class AudioSessionEngineObserver: AudioEngineObserver, Loggable, @unchecked Sendable {
    /// Controls automatic configuration of the `AVAudioSession` based on audio engine state.
    ///
    /// - When `true`: The `AVAudioSession` is automatically configured based on the audio engine state
    /// - When `false`: Manual configuration of the `AVAudioSession` is required
    ///
    /// > Note: It is recommended to set this value before connecting to a room.
    ///
    /// Default value: `true`
    public var isAutomaticConfigurationEnabled: Bool {
        get { _state.isAutomaticConfigurationEnabled }
        set { _state.mutate { $0.isAutomaticConfigurationEnabled = newValue } }
    }

    /// Controls whether the audio session is deactivated when the audio engine stops.
    ///
    /// - When `true`: The `AVAudioSession` is deactivated when both playout and recording are disabled
    /// - When `false`: The `AVAudioSession` remains active when the audio engine stops
    ///
    /// > Note: This value is only used when `isAutomaticConfigurationEnabled` is `true`.
    ///
    /// > Tip: Set to `false` if your app has other audio features that could be disrupted
    /// > by deactivating the audio session.
    ///
    /// Default value: `true`
    public var isAutomaticDeactivationEnabled: Bool {
        get { _state.isAutomaticDeactivationEnabled }
        set { _state.mutate { $0.isAutomaticDeactivationEnabled = newValue } }
    }

    /// Controls the speaker output preference for audio routing.
    ///
    /// - When `true`: The speaker output is preferred over the receiver output
    /// - When `false`: The receiver output is preferred over the speaker output
    ///
    /// > Note: This value is only used when `isAutomaticConfigurationEnabled` is `true`.
    ///
    /// Default value: `true`
    public var isSpeakerOutputPreferred: Bool {
        get { _state.isSpeakerOutputPreferred }
        set { _state.mutate { $0.isSpeakerOutputPreferred = newValue } }
    }

    struct State {
        var next: (any AudioEngineObserver)?

        var isAutomaticConfigurationEnabled: Bool = true
        var isAutomaticDeactivationEnabled: Bool = true
        var isPlayoutEnabled: Bool = false
        var isRecordingEnabled: Bool = false
        var isSpeakerOutputPreferred: Bool = true
    }

    let _state = StateSync(State())

    public var next: (any AudioEngineObserver)? {
        get { _state.next }
        set { _state.mutate { $0.next = newValue } }
    }

    public init() {
        _state.onDidMutate = { [weak self] new, old in
            guard let self,
                  new.isSpeakerOutputPreferred != old.isSpeakerOutputPreferred else { return }
            _ = configureIfNeeded(oldState: old, newState: new)
        }
    }

    // MARK: - Audio Session Configuration

    private func configureIfNeeded(oldState: State, newState: State) -> Int {
        guard newState.isAutomaticConfigurationEnabled else { return 0 }

        // Deprecated: `customConfigureAudioSessionFunc` overrides the default configuration.
        // This path does not support error propagation since the legacy func returns Void.
        // Use `set(engineObservers:)` with a custom `AudioEngineObserver` instead.
        if let legacyConfigFunc = AudioManager.shared._state.customConfigureFunc {
            let oldLegacy = AudioManager.State(localTracksCount: oldState.isRecordingEnabled ? 1 : 0, remoteTracksCount: oldState.isPlayoutEnabled ? 1 : 0)
            let newLegacy = AudioManager.State(localTracksCount: newState.isRecordingEnabled ? 1 : 0, remoteTracksCount: newState.isPlayoutEnabled ? 1 : 0)
            legacyConfigFunc(newLegacy, oldLegacy)
            return 0
        }

        do {
            try configureAudioSession(oldState: oldState, newState: newState)
            return 0
        } catch {
            return kAudioEngineErrorFailedToConfigureAudioSession
        }
    }

    @Sendable private func configureAudioSession(oldState: State, newState: State) throws {
        let session = AVAudioSession.sharedInstance()

        if (!newState.isPlayoutEnabled && !newState.isRecordingEnabled) && (oldState.isPlayoutEnabled || oldState.isRecordingEnabled) {
            if newState.isAutomaticDeactivationEnabled {
                do {
                    log("AudioSession deactivating...")
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    log("AudioSession failed to deactivate with error: \(error)", .error)
                    throw error
                }
            } else {
                log("AudioSession deactivation skipped...")
            }
        } else if newState.isRecordingEnabled || newState.isPlayoutEnabled {
            // Configure and activate the session with the appropriate category
            let playAndRecord: AudioSessionConfiguration = newState.isSpeakerOutputPreferred ? .playAndRecordSpeaker : .playAndRecordReceiver
            let config: AudioSessionConfiguration = newState.isRecordingEnabled ? playAndRecord : .playback

            do {
                log("AudioSession configuring category to: \(config.category)")
                try session.setCategory(config.category, mode: config.mode, options: config.categoryOptions)
                // Request WebRTC's preferred IO buffer duration (0.02s / 20ms, defined as
                // RTCAudioSessionHighPerformanceIOBufferDuration in RTCAudioSessionConfiguration.m).
                // WebRTC also sets this internally via RTCAudioSession+Configuration.mm when
                // configuring the audio session, but we set it here as well since we manage the
                // session category ourselves. This is only a hint, iOS may ignore it and negotiate
                // a larger buffer on some devices, causing kAudioUnitErr_TooManyFramesToProcess (-10874).
                // As a fallback, MixerEngineObserver sets maximumFramesToRender on its nodes to
                // handle larger-than-expected buffer sizes.
                // See: https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferrediobufferduration(_:)
                // See: https://developer.apple.com/library/archive/qa/qa1631/_index.html
                try session.setPreferredIOBufferDuration(LKRTCAudioSessionConfiguration.webRTC().ioBufferDuration)
            } catch {
                log("AudioSession failed to configure with error: \(error)", .error)
                throw error
            }

            if !oldState.isPlayoutEnabled, !oldState.isRecordingEnabled {
                do {
                    log("AudioSession activating...")
                    try session.setActive(true)
                } catch {
                    log("AudioSession failed to activate AudioSession with error: \(error)", .error)
                    throw error
                }
            }
        }
    }

    // MARK: - AudioEngineObserver

    public func engineWillEnable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        let result: Int = _state.mutate {
            let oldState = $0
            $0.isPlayoutEnabled = isPlayoutEnabled
            $0.isRecordingEnabled = isRecordingEnabled
            let result = configureIfNeeded(oldState: oldState, newState: $0)
            if result != 0 {
                // Rollback state on failure so it stays consistent with WebRTC's rollback.
                $0 = oldState
            }
            return result
        }
        guard result == 0 else { return result }
        return _state.next?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    public func engineDidDisable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        let nextResult = _state.next?.engineDidDisable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0

        let result: Int = _state.mutate {
            let oldState = $0
            $0.isPlayoutEnabled = isPlayoutEnabled
            $0.isRecordingEnabled = isRecordingEnabled
            let result = configureIfNeeded(oldState: oldState, newState: $0)
            if result != 0 {
                // Rollback state on failure so it stays consistent with WebRTC's rollback.
                $0 = oldState
            }
            return result
        }
        guard result == 0 else { return result }
        return nextResult
    }
}

#endif
