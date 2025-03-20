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

let kFailedToConfigureAudioSessionErrorCode = -4100

#if os(iOS) || os(visionOS) || os(tvOS)

import AVFoundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

public class DefaultAudioSessionObserver: AudioEngineObserver, Loggable, @unchecked Sendable {
    struct State {
        var next: (any AudioEngineObserver)?

        // Used for backward compatibility with `customConfigureAudioSessionFunc`.
        var isPlayoutEnabled: Bool = false
        var isRecordingEnabled: Bool = false
    }

    let _state = StateSync(State())

    public var next: (any AudioEngineObserver)? {
        get { _state.next }
        set { _state.mutate { $0.next = newValue } }
    }

    public init() {
        // Backward compatibility with `customConfigureAudioSessionFunc`.
        _state.onDidMutate = { new_, old_ in
            if let config_func = AudioManager.shared._state.customConfigureFunc,
               new_.isPlayoutEnabled != old_.isPlayoutEnabled ||
               new_.isRecordingEnabled != old_.isRecordingEnabled
            {
                // Simulate state and invoke custom config func.
                let old_state = AudioManager.State(localTracksCount: old_.isRecordingEnabled ? 1 : 0, remoteTracksCount: old_.isPlayoutEnabled ? 1 : 0)
                let new_state = AudioManager.State(localTracksCount: new_.isRecordingEnabled ? 1 : 0, remoteTracksCount: new_.isPlayoutEnabled ? 1 : 0)
                config_func(new_state, old_state)
            }
        }
    }

    public func engineWillEnable(_ engine: AVAudioEngine, state: AudioEngineStateTransition) -> Int {
        if AudioManager.shared._state.customConfigureFunc == nil {
            let session = LKRTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }

            let newConfig: AudioSessionConfiguration = state.next.isInputEnabled ? .playAndRecordSpeaker : .playback
            if session.category != newConfig.category.rawValue || session.mode != newConfig.mode.rawValue {
                do {
                    log("AudioSession switching category: \(session.category) -> \(newConfig.category.rawValue), mode: \(session.mode) -> \(newConfig.mode.rawValue)")
                    try session.setConfiguration(newConfig.toRTCType())
                } catch {
                    log("AudioSession switch category with error: \(error)", .error)
                    return kFailedToConfigureAudioSessionErrorCode
                }
            }

            if !session.isActive {
                do {
                    log("AudioSession activating...")
                    try session.setActive(true)
                } catch {
                    log("AudioSession failed to activate with error: \(error)", .error)
                    return kFailedToConfigureAudioSessionErrorCode
                }
            }

            log("AudioSession activationCount: \(session.activationCount), webRTCSessionCount: \(session.webRTCSessionCount)")
        }

        _state.mutate {
            $0.isPlayoutEnabled = state.next.isOutputEnabled
            $0.isRecordingEnabled = state.next.isInputEnabled
        }

        // Call next last
        return _state.next?.engineWillEnable(engine, state: state) ?? 0
    }

    public func engineDidDisable(_ engine: AVAudioEngine, state: AudioEngineStateTransition) -> Int {
        // Call next first
        let nextResult = _state.next?.engineDidDisable(engine, state: state)

        _state.mutate {
            $0.isPlayoutEnabled = state.next.isOutputEnabled
            $0.isRecordingEnabled = state.next.isInputEnabled
        }

        if AudioManager.shared._state.customConfigureFunc == nil {
            let session = LKRTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }

            var newConfig: AudioSessionConfiguration? = nil

            // Only when input was disabled
            if state.prev.isOutputEnabled, state.next.isOutputEnabled, state.prev.isInputEnabled, !state.next.isInputEnabled {
                let didLegacyMute = (!state.prev.isLegacyMuteMode && state.next.isLegacyMuteMode && state.next.isInputMuted) ||
                    (!state.prev.isInputMuted && state.next.isInputMuted && state.next.isLegacyMuteMode)

                newConfig = didLegacyMute ? .playAndRecordDefault : .playback
            }

            if let newConfig, session.category != newConfig.category.rawValue || session.mode != newConfig.mode.rawValue {
                do {
                    log("AudioSession switching category: \(session.category) -> \(newConfig.category.rawValue), mode: \(session.mode) -> \(newConfig.mode.rawValue)")
                    try session.setConfiguration(newConfig.toRTCType())
                } catch {
                    log("AudioSession failed to switch category with error: \(error)", .error)
                }
            }

            if !state.next.isOutputEnabled, !state.next.isInputEnabled, session.isActive {
                do {
                    log("AudioSession deactivating...")
                    try session.setActive(false)
                } catch {
                    log("AudioSession failed to deactivate with error: \(error)", .error)
                }
            }

            log("AudioSession activationCount: \(session.activationCount), webRTCSessionCount: \(session.webRTCSessionCount)")
        }

        return nextResult ?? 0
    }
}

#endif
