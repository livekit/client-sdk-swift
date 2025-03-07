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
        var isSessionActive = false
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

    public func engineWillEnable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        if AudioManager.shared._state.customConfigureFunc == nil {
            log("Configuring audio session...")
            let session = LKRTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }

            if _state.isSessionActive {
                do {
                    log("AudioSession deactivating due to category switch")
                    try session.setActive(false) // Deactivate first
                    _state.mutate { $0.isSessionActive = false }
                } catch {
                    log("Failed to deactivate AudioSession with error: \(error)", .error)
                }
            }

            let config: AudioSessionConfiguration = isRecordingEnabled ? .playAndRecordSpeaker : .playback
            do {
                log("AudioSession activating category to: \(config.category)")
                try session.setConfiguration(config.toRTCType(), active: true)
                _state.mutate { $0.isSessionActive = true }
            } catch {
                log("AudioSession failed to configure with error: \(error)", .error)
                // Pass error code to audio engine
                return kFailedToConfigureAudioSessionErrorCode
            }

            log("AudioSession activationCount: \(session.activationCount), webRTCSessionCount: \(session.webRTCSessionCount)")
        }

        _state.mutate {
            $0.isPlayoutEnabled = isPlayoutEnabled
            $0.isRecordingEnabled = isRecordingEnabled
        }

        // Call next last
        return _state.next?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    public func engineDidDisable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        // Call next first
        let nextResult = _state.next?.engineDidDisable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)

        _state.mutate {
            $0.isPlayoutEnabled = isPlayoutEnabled
            $0.isRecordingEnabled = isRecordingEnabled
        }

        if AudioManager.shared._state.customConfigureFunc == nil {
            log("Configuring audio session...")
            let session = LKRTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }

            do {
                if isPlayoutEnabled, !isRecordingEnabled {
                    let config: AudioSessionConfiguration = .playback
                    log("AudioSession switching category to: \(config.category)")
                    try session.setConfiguration(config.toRTCType())
                }
                if !isPlayoutEnabled, !isRecordingEnabled, _state.isSessionActive {
                    log("AudioSession deactivating")
                    try session.setActive(false)
                    _state.mutate { $0.isSessionActive = false }
                }
            } catch {
                log("AudioSession failed to configure with error: \(error)", .error)
            }

            log("AudioSession activationCount: \(session.activationCount), webRTCSessionCount: \(session.webRTCSessionCount)")
        }

        return nextResult ?? 0
    }
}

#endif
