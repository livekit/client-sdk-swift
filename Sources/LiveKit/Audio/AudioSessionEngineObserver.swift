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

    public struct SessionRequirement: Sendable {
        public static let none = Self(isPlayoutEnabled: false, isRecordingEnabled: false)
        public static let playbackOnly = Self(isPlayoutEnabled: true, isRecordingEnabled: false)
        public static let recordingOnly = Self(isPlayoutEnabled: false, isRecordingEnabled: true)
        public static let playbackAndRecording = Self(isPlayoutEnabled: true, isRecordingEnabled: true)

        public let isPlayoutEnabled: Bool
        public let isRecordingEnabled: Bool

        public init(isPlayoutEnabled: Bool = false, isRecordingEnabled: Bool = false) {
            self.isPlayoutEnabled = isPlayoutEnabled
            self.isRecordingEnabled = isRecordingEnabled
        }
    }

    struct State: Sendable {
        var next: (any AudioEngineObserver)?

        var isAutomaticConfigurationEnabled: Bool = true
        var isAutomaticDeactivationEnabled: Bool = true
        var isPlayoutEnabled: Bool = false
        var isRecordingEnabled: Bool = false
        var isSpeakerOutputPreferred: Bool = true

        //
        var sessionRequirements: [UUID: SessionRequirement] = [:]

        // Computed
        var isPlayoutEnabled: Bool { sessionRequirements.values.contains(where: \.isPlayoutEnabled) }
        var isRecordingEnabled: Bool { sessionRequirements.values.contains(where: \.isRecordingEnabled) }
    }

    let _state = StateSync(State())

    // Session requirement id for this object
    private let sessionRequirementId = UUID()

    public var next: (any AudioEngineObserver)? {
        get { _state.next }
        set { _state.mutate { $0.next = newValue } }
    }

    public init() {
        _state.onDidMutate = { new_, old_ in
            if new_.isAutomaticConfigurationEnabled, new_.isPlayoutEnabled != old_.isPlayoutEnabled ||
                new_.isRecordingEnabled != old_.isRecordingEnabled ||
                new_.isSpeakerOutputPreferred != old_.isSpeakerOutputPreferred
            {
                // Legacy config func
                if let config_func = AudioManager.shared._state.customConfigureFunc {
                    // Simulate state and invoke custom config func.
                    let old_state = AudioManager.State(localTracksCount: old_.isRecordingEnabled ? 1 : 0, remoteTracksCount: old_.isPlayoutEnabled ? 1 : 0)
                    let new_state = AudioManager.State(localTracksCount: new_.isRecordingEnabled ? 1 : 0, remoteTracksCount: new_.isPlayoutEnabled ? 1 : 0)
                    config_func(new_state, old_state)
                } else {
                    self.configure(oldState: old_, newState: new_)
                }
            }
        }
    }

    public func set(requirement: SessionRequirement, for id: UUID) {
        _state.mutate { $0.sessionRequirements[id] = requirement }
    }

    @Sendable func configure(oldState: State, newState: State) {
        let session = AVAudioSession.sharedInstance()

        log("configure isRecordingEnabled: \(newState.isRecordingEnabled), isPlayoutEnabled: \(newState.isPlayoutEnabled)")

        if (!newState.isPlayoutEnabled && !newState.isRecordingEnabled) && (oldState.isPlayoutEnabled || oldState.isRecordingEnabled) {
            if newState.isAutomaticDeactivationEnabled {
                do {
                    log("AudioSession deactivating...")
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    log("AudioSession failed to deactivate with error: \(error)", .error)
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
            } catch {
                log("AudioSession failed to configure with error: \(error)", .error)
            }

            if !oldState.isPlayoutEnabled, !oldState.isRecordingEnabled {
                do {
                    log("AudioSession activating...")
                    try session.setActive(true)
                } catch {
                    log("AudioSession failed to activate AudioSession with error: \(error)", .error)
                }
            }
        }
    }

    public func engineWillEnable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        let requirement = SessionRequirement(isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
        set(requirement: requirement, for: sessionRequirementId)

        // Call next last
        return _state.next?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    public func engineDidDisable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        // Call next first
        let nextResult = _state.next?.engineDidDisable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)

        let requirement = SessionRequirement(isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
        set(requirement: requirement, for: sessionRequirementId)

        return nextResult ?? 0
    }
}

#endif
