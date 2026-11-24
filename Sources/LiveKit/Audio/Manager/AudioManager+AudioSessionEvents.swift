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

import AVFAudio

public extension AudioManager {
    typealias OnAudioSessionEvent = @Sendable (_ audioManager: AudioManager, _ event: AudioSessionEvent) -> Void

    /// Called for audio session interruptions and media services resets reported by the audio engine.
    ///
    /// ```swift
    /// AudioManager.shared.onAudioSessionEvent = { _, event in
    ///     switch event {
    ///     case let .interruptionBegan(reason): print("Interrupted: \(reason)")
    ///     case let .interruptionEnded(shouldResume): print("Interruption ended, resume: \(shouldResume)")
    ///     case .mediaServicesWereReset: print("Media services were reset")
    ///     }
    /// }
    /// ```
    ///
    /// - Important: Called on WebRTC's worker thread, which the audio engine waits on until this returns.
    ///   Return quickly and dispatch any work to another queue. Do not call `AVAudioSession` APIs or
    ///   ``AudioManager``'s synchronous methods (for example ``setEngineAvailability(_:)``) from this callback.
    /// - Note: Engine observers set with ``set(engineObservers:)`` receive the same events, before this is called.
    ///   When ``AudioSessionEngineObserver/isAutomaticConfigurationEnabled`` is `false`, the SDK does not touch
    ///   the audio session in response to these events; reconfigure and reactivate it yourself.
    var onAudioSessionEvent: OnAudioSessionEvent? {
        get { _state.onAudioSessionEvent }
        set { _state.mutate { $0.onAudioSessionEvent = newValue } }
    }

    /// Whether the audio session is interrupted, between ``AudioSessionEvent/interruptionBegan(reason:)``
    /// and ``AudioSessionEvent/interruptionEnded(shouldResume:)``.
    var isAudioSessionInterrupted: Bool {
        _state.isAudioSessionInterrupted
    }
}

extension AudioManager {
    /// Delivers an audio session event reported by the audio device module.
    /// Called on WebRTC's worker thread: must not call `AVAudioSession` or the audio device module synchronously.
    func handle(audioSessionEvent event: AudioSessionEvent) {
        let onAudioSessionEvent = _state.mutate {
            switch event {
            case .interruptionBegan: $0.isAudioSessionInterrupted = true
            case .interruptionEnded: $0.isAudioSessionInterrupted = false
            case .mediaServicesWereReset: break
            }
            return $0.onAudioSessionEvent
        }

        let session = audioSession._state.copy()
        log("Audio session event: \(event), session observer: automaticConfiguration: \(session.isAutomaticConfigurationEnabled), isPlayoutEnabled: \(session.isPlayoutEnabled), isRecordingEnabled: \(session.isRecordingEnabled), isInChain: \(isAudioSessionObserverInChain)", .info)

        if let entryPoint = buildEngineObserverChain() {
            switch event {
            case let .interruptionBegan(reason): entryPoint.audioSessionDidBeginInterruption(reason: reason)
            case let .interruptionEnded(shouldResume): entryPoint.audioSessionDidEndInterruption(shouldResume: shouldResume)
            case .mediaServicesWereReset: entryPoint.audioSessionMediaServicesWereReset()
            }
        }

        onAudioSessionEvent?(self, event)
    }

    /// Whether the SDK's own ``AudioSessionEngineObserver`` is part of the engine observer chain, so the SDK manages the session.
    var isAudioSessionObserverInChain: Bool {
        _state.engineObservers.contains { ($0 as AnyObject) === audioSession }
    }
}

#endif
