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

/// An audio session event reported by the audio engine.
///
/// - SeeAlso: ``AudioManager/onAudioSessionEvent``
public enum AudioSessionEvent: Sendable, Equatable {
    /// The audio session was interrupted, for example by a phone call or an alarm.
    /// The system has usually stopped the audio engine already.
    case interruptionBegan(reason: AVAudioSession.InterruptionReason)

    /// An audio session interruption ended, and the audio engine is about to restart.
    ///
    /// Also reported each time the app becomes active and when the session is activated externally
    /// (for example by CallKit), so it can arrive without a preceding ``interruptionBegan(reason:)``.
    /// `shouldResume` is the system's `AVAudioSession.InterruptionOptions.shouldResume` hint.
    /// The audio engine restarts whatever its value.
    case interruptionEnded(shouldResume: Bool)

    /// The system reset its media services. The audio session lost its configuration and every
    /// audio object created before the reset, including the audio engine, no longer works.
    case mediaServicesWereReset
}

#endif
