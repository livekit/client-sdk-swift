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

public extension AudioSessionEngineObserver {
    /// Records that the system deactivated the session, so the next engine start reactivates it.
    func audioSessionDidBeginInterruption(reason: AVAudioSession.InterruptionReason) {
        _state.mutate {
            $0.isInterrupted = true
            $0.needsActivation = true
        }
        next?.audioSessionDidBeginInterruption(reason: reason)
    }

    /// Records the end of an interruption. The audio device module restarts the engine right after
    /// this returns, and ``engineWillStart(_:isPlayoutEnabled:isRecordingEnabled:)`` reapplies the
    /// configuration and reactivates the session before it does.
    func audioSessionDidEndInterruption(shouldResume: Bool) {
        _state.mutate {
            $0.isInterrupted = false
            $0.shouldResumeAfterInterruption = shouldResume
        }
        next?.audioSessionDidEndInterruption(shouldResume: shouldResume)
    }

    /// Reapplies the session configuration and reactivates the session when the engine restarts after an
    /// interruption. The audio device module only calls `engineWillStart` then, not `engineWillEnable`.
    ///
    /// Only when ``isAutomaticConfigurationEnabled`` is `true`, an interruption began since the session was
    /// last activated, it has ended, and the system did not ask to leave resuming to the user. A failure is
    /// logged and does not fail the start: the engine restarts as it would without this step. Activation
    /// fails in the background or in a CallKit call that CallKit has not reactivated.
    func engineWillStart(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        if !engine.isInManualRenderingMode {
            reactivateSessionAfterInterruptionIfNeeded()
        }
        return next?.engineWillStart(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }
}

extension AudioSessionEngineObserver {
    func reactivateSessionAfterInterruptionIfNeeded() {
        let shouldReactivate = _state.read {
            $0.isAutomaticConfigurationEnabled && $0.needsActivation && !$0.isInterrupted && $0.shouldResumeAfterInterruption
        }
        guard shouldReactivate else { return }

        do {
            log("Reactivating the audio session after an interruption")
            try reactivateSessionIfNeeded()
        } catch {
            log("Failed to reactivate the audio session after an interruption, starting the engine anyway: \(error)", .warning)
        }
    }
}

#endif
