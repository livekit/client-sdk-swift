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

    /// Whether the active local participant has permission to publish microphone
    /// audio. Defaults to `true` (optimistic) until permissions arrive from the
    /// server. Gates the pre-emptive `.playAndRecord` upgrade when the app sets
    /// `isRecordingAlwaysPreparedMode`; once recording actually engages on any
    /// path the sticky bit and `isRecordingEnabled` take over and override.
    var canPublishMicrophone: Bool {
        get { _state.canPublishMicrophone }
        set { _state.mutate { $0.canPublishMicrophone = newValue } }
    }

    struct State {
        var next: (any AudioEngineObserver)?

        var isAutomaticConfigurationEnabled: Bool = true
        var isAutomaticDeactivationEnabled: Bool = true
        var isSpeakerOutputPreferred: Bool = true

        var sessionRequirements: [UUID: SessionRequirement] = [:]

        // Sticky: true once recording engaged this session, cleared on the empty edge.
        // Keeps `.playAndRecord` across mute toggles instead of churning the category
        // on every requirement change.
        var hasRecorded: Bool = false

        // Tracks the active local participant's mic publish permission. See accessor.
        var canPublishMicrophone: Bool = true
    }

    let _state = StateSync(State())

    private let sessionRequirementId = UUID()

    public var next: (any AudioEngineObserver)? {
        get { _state.next }
        set { _state.mutate { $0.next = newValue } }
    }

    // Listens to iOS-driven session events (interruption-end, externally-driven
    // category change) that may leave the session in a state different from
    // what we configured. Held as a strong reference because `LKRTCAudioSession`
    // stores its delegates weakly.
    private let rtcDelegateAdapter = RTCAudioSessionDelegateAdapter()

    public init() {
        _state.onDidMutate = { [weak self] new, old in
            guard let self,
                  new.isSpeakerOutputPreferred != old.isSpeakerOutputPreferred else { return }
            do {
                try configureIfNeeded(oldState: old, newState: new)
            } catch {
                log("Failed to configure audio session after speaker preference change: \(error)", .error)
            }
        }

        rtcDelegateAdapter.owner = self
        LKRTCAudioSession.sharedInstance().add(rtcDelegateAdapter)
    }

    /// Acquires an audio session requirement handle for external ownership.
    ///
    /// Use this to keep the audio session active from external components
    /// (e.g., ``SoundPlayer``) that need playout or recording independently
    /// of the WebRTC engine lifecycle.
    ///
    /// - Throws: ``LiveKitError`` if the audio session fails to configure or activate.
    public func acquire(requirement: SessionRequirement) throws -> SessionRequirementHandle {
        let id = UUID()
        try set(requirement: requirement, for: id)
        return SessionRequirementHandle(releaseImpl: { [weak self] in
            guard let self else { return }
            try removeRequirement(for: id)
        })
    }

    private func set(requirement: SessionRequirement, for id: UUID) throws {
        try updateRequirements {
            if requirement == .none {
                $0.removeValue(forKey: id)
            } else {
                $0[id] = requirement
            }
        }
    }

    fileprivate func removeRequirement(for id: UUID) throws {
        try updateRequirements {
            $0.removeValue(forKey: id)
        }
    }

    private func updateRequirements(_ block: (inout [UUID: SessionRequirement]) -> Void) throws {
        try _state.mutate {
            let oldState = $0
            block(&$0.sessionRequirements)
            guard $0.sessionRequirements != oldState.sessionRequirements else { return }

            // Maintain the sticky `hasRecorded` bit.
            if $0.isRecordingEnabled {
                $0.hasRecorded = true
            } else if !$0.isPlayoutEnabled {
                // Empty edge — reset for the next session.
                $0.hasRecorded = false
            }

            do {
                try configureIfNeeded(oldState: oldState, newState: $0)
            } catch {
                $0 = oldState
                throw LiveKitError(.audioSession, message: "Failed to configure audio session")
            }
        }
    }

    // MARK: - Audio Session Configuration

    private func configureIfNeeded(oldState: State, newState: State) throws {
        guard newState.isAutomaticConfigurationEnabled else { return }

        // Deprecated: `customConfigureAudioSessionFunc` overrides the default configuration.
        // This path does not support error propagation since the legacy func returns Void.
        // Use `set(engineObservers:)` with a custom `AudioEngineObserver` instead.
        if let legacyConfigFunc = AudioManager.shared._state.customConfigureFunc {
            let oldLegacy = AudioManager.State(localTracksCount: oldState.isRecordingEnabled ? 1 : 0, remoteTracksCount: oldState.isPlayoutEnabled ? 1 : 0)
            let newLegacy = AudioManager.State(localTracksCount: newState.isRecordingEnabled ? 1 : 0, remoteTracksCount: newState.isPlayoutEnabled ? 1 : 0)
            legacyConfigFunc(newLegacy, oldLegacy)
            return
        }

        try configureAudioSession(oldState: oldState, newState: newState)
    }

    @Sendable private func configureAudioSession(oldState: State, newState: State) throws {
        let session = AVAudioSession.sharedInstance()

        log("configure isRecordingEnabled: \(newState.isRecordingEnabled), isPlayoutEnabled: \(newState.isPlayoutEnabled)")

        if (!newState.isPlayoutEnabled && !newState.isRecordingEnabled) && (oldState.isPlayoutEnabled || oldState.isRecordingEnabled) {
            if newState.isAutomaticDeactivationEnabled {
                do {
                    log("AudioSession resetting to ambient and deactivating...")
                    // Restore the media volume register; rocker stays on ringer/call otherwise.
                    let idle = AudioSessionConfiguration.ambient
                    try session.setCategory(idle.category, mode: idle.mode, options: idle.categoryOptions)
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    log("AudioSession failed to deactivate with error: \(error)", .error)
                    throw error
                }
            } else {
                log("AudioSession deactivation skipped...")
            }
        } else if newState.isRecordingEnabled || newState.isPlayoutEnabled {
            let config = selectConfiguration(state: newState)

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

    /// Picks the audio session configuration for the current state.
    ///
    /// `.playAndRecord` is selected when any signal indicates the user is or
    /// will be publishing; otherwise `.playback` (pure listener):
    ///   - `isRecordingEnabled`: a track or external acquirer needs recording now.
    ///   - `hasRecorded`: sticky — keeps `.playAndRecord` across mute toggles.
    ///   - `wantsToPublish`: either signal of publishing intent —
    ///     server-issued mic permission (`canPublishMicrophone`) or the
    ///     app-declared `isRecordingAlwaysPreparedMode`.
    private func selectConfiguration(state: State) -> AudioSessionConfiguration {
        let wantsToPublish = state.canPublishMicrophone || AudioManager.shared.isRecordingAlwaysPreparedMode
        let needsRecord = state.isRecordingEnabled || state.hasRecorded || wantsToPublish
        let config: AudioSessionConfiguration = needsRecord
            ? (state.isSpeakerOutputPreferred ? .playAndRecordSpeaker : .playAndRecordReceiver)
            : .playback
        log("selectConfiguration: recording=\(state.isRecordingEnabled) hasRecorded=\(state.hasRecorded) canPublishMic=\(state.canPublishMicrophone) speaker=\(state.isSpeakerOutputPreferred) → \(config.category)")
        return config
    }

    /// Re-applies the current category/mode/options after an external event
    /// (interruption-end, category-change) that may have mutated the session.
    /// WebRTC re-activates the session on these events but does not re-apply
    /// our configuration; iOS can leave us in a state different from what we
    /// configured.
    ///
    /// Also calls `overrideOutputAudioPort` as a workaround for a VPIO
    /// low-volume regression where audio comes back inaudibly quiet after
    /// resume (#1011); toggling the output port forces a fresh route
    /// selection that picks up the correct gain.
    fileprivate func reapplyConfiguration(reason: String) {
        let snapshot = _state.copy()
        guard snapshot.isAutomaticConfigurationEnabled else { return }
        guard snapshot.isPlayoutEnabled || snapshot.isRecordingEnabled else { return }

        let config = selectConfiguration(state: snapshot)
        let session = AVAudioSession.sharedInstance()
        do {
            log("AudioSession re-applying configuration (\(reason)) to: \(config.category)")
            try session.setCategory(config.category, mode: config.mode, options: config.categoryOptions)
            try session.setPreferredIOBufferDuration(LKRTCAudioSessionConfiguration.webRTC().ioBufferDuration)
            if config.category == .playAndRecord {
                try session.overrideOutputAudioPort(snapshot.isSpeakerOutputPreferred ? .speaker : .none)
            }
        } catch {
            log("AudioSession failed to re-apply configuration: \(error)", .error)
        }
    }

    // MARK: - AudioEngineObserver

    public func engineWillEnable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        // No device access in manual rendering mode, skip session requirement.
        if engine.isInManualRenderingMode {
            return _state.next?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
        }

        let requirement = SessionRequirement(isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
        do {
            try set(requirement: requirement, for: sessionRequirementId)
        } catch {
            return kAudioEngineErrorFailedToConfigureAudioSession
        }
        return _state.next?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    public func engineDidDisable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        let nextResult = _state.next?.engineDidDisable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0

        if engine.isInManualRenderingMode {
            return nextResult
        }

        let requirement = SessionRequirement(isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
        do {
            try set(requirement: requirement, for: sessionRequirementId)
        } catch {
            return kAudioEngineErrorFailedToConfigureAudioSession
        }
        return nextResult
    }
}

extension AudioSessionEngineObserver.State {
    var isPlayoutEnabled: Bool { sessionRequirements.values.contains(where: \.isPlayoutEnabled) }
    var isRecordingEnabled: Bool { sessionRequirements.values.contains(where: \.isRecordingEnabled) }
}

// MARK: - LKRTCAudioSessionDelegate

/// Forwards iOS-driven session events to ``AudioSessionEngineObserver``
/// so the configuration can be re-applied when needed.
private final class RTCAudioSessionDelegateAdapter: NSObject, LKRTCAudioSessionDelegate, Loggable {
    weak var owner: AudioSessionEngineObserver?

    /// iOS finished an interruption (cellular call, alarm, Siri, FaceTime, …).
    /// WebRTC re-activates the session here but does not re-apply our
    /// category/mode/options.
    func audioSessionDidEndInterruption(_: LKRTCAudioSession, shouldResumeSession: Bool) {
        guard shouldResumeSession else {
            log("AudioSession interruption ended (shouldResumeSession=false); skipping re-apply")
            return
        }
        owner?.reapplyConfiguration(reason: "interruption-end")
    }

    /// iOS reported a route change. Only re-apply for reasons that suggest the
    /// session configuration was mutated externally (CallKit activation, system
    /// audio takeover); user/system port overrides and BT route connect/
    /// disconnect manage themselves.
    func audioSessionDidChangeRoute(_: LKRTCAudioSession,
                                    reason: AVAudioSession.RouteChangeReason,
                                    previousRoute _: AVAudioSessionRouteDescription)
    {
        switch reason {
        case .categoryChange, .routeConfigurationChange:
            owner?.reapplyConfiguration(reason: "route-change(\(reason))")
        default:
            log("AudioSession route changed (not handled): \(reason)")
        }
    }
}

#endif
