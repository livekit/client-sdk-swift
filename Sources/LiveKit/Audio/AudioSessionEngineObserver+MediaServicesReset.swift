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
    /// Recovers audio after a media services reset.
    ///
    /// The reset dropped the session's category, mode and options and left the audio engine dead. When
    /// ``isAutomaticConfigurationEnabled`` is `true`, the observer marks the session as needing activation and,
    /// off WebRTC's worker thread, reconfigures and reactivates the session, then rebuilds the engine (keeping the
    /// app's ``AudioManager/engineAvailability``). When it is `false`, the session and the engine are left to
    /// the app: reconfigure and reactivate the session, then rebuild the engine by setting
    /// ``AudioManager/setEngineAvailability(_:)`` to ``AudioEngineAvailability/none`` and back.
    func audioSessionMediaServicesWereReset() {
        let isAutomaticConfigurationEnabled = _state.mutate {
            $0.needsActivation = true
            return $0.isAutomaticConfigurationEnabled
        }

        if isAutomaticConfigurationEnabled {
            Task.detached { [self] in
                await MediaServicesResetRecovery.run(audioSession: self)
            }
        } else {
            log("Media services were reset, automatic configuration is disabled: the app must reconfigure the audio session and rebuild the engine", .warning)
        }

        next?.audioSessionMediaServicesWereReset()
    }
}

extension AudioSessionEngineObserver {
    /// Acquires a requirement equal to what the session is currently required for, so the session stays
    /// active and configured while the engine gives up and re-acquires its own requirement.
    ///
    /// - Returns: `nil` when nothing requires the session, or when the requirement could not be acquired.
    func acquireCurrentRequirement() -> SessionRequirementHandle? {
        let current = _state.read {
            SessionRequirement(isPlayoutEnabled: $0.isPlayoutEnabled, isRecordingEnabled: $0.isRecordingEnabled)
        }
        guard current != .none else { return nil }

        do {
            return try acquire(requirement: current)
        } catch {
            log("Failed to hold the audio session across the engine rebuild: \(error)", .warning)
            return nil
        }
    }
}

#endif
