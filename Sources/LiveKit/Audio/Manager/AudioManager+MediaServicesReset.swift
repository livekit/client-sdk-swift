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

internal import LiveKitWebRTC

/// Rebuilds the audio engine and reactivates the audio session after a media services reset.
///
/// The audio device module does not react to the reset: its state still says the engine runs, so audio
/// stays dead until something releases the engine and creates a new one. Turning engine availability off
/// and back on does that, and the new engine's `engineWillEnable` reconfigures and reactivates the session
/// through ``AudioSessionEngineObserver``. Runs on the `@RTC` executor, never on WebRTC's worker thread.
enum MediaServicesResetRecovery: Loggable {
    static let restoreAttempts = 3
    static let restoreRetryDelayNanoseconds: UInt64 = 500_000_000

    static func run(audioSession: AudioSessionEngineObserver) async {
        // Configure and activate the session before the engine is rebuilt, as the audio device module
        // asks: the new engine checks the session category before it starts. This also covers session
        // requirements held without the engine (SoundPlayer, for example).
        do {
            try await RTC.run { try audioSession.reactivateSessionIfNeeded() }
        } catch {
            log("Failed to reactivate the audio session after a media services reset: \(error)", .error)
        }

        let availability = await RTC.run { RTC.audioDeviceModule.engineAvailability.toLKType() }

        if availability.isInputAvailable || availability.isOutputAvailable {
            await rebuildEngine(restoring: availability)
        } else {
            // The app keeps the engine unavailable (CallKit, for example). A new engine is created when it
            // makes the engine available again, so availability is left untouched.
            log("Media services were reset while the audio engine is unavailable, not rebuilding it")
        }
    }

    private static func rebuildEngine(restoring availability: AudioEngineAvailability) async {
        log("Rebuilding the audio engine after a media services reset", .info)

        let releaseResult = await RTC.run {
            RTC.audioDeviceModule.setEngineAvailability(AudioEngineAvailability.none.toRTCType())
        }
        guard releaseResult == 0 else {
            log("Failed to release the audio engine after a media services reset, error: \(releaseResult)", .error)
            return
        }

        for attempt in 1 ... restoreAttempts {
            let result = await RTC.run { RTC.audioDeviceModule.setEngineAvailability(availability.toRTCType()) }
            if result == 0 {
                log("Rebuilt the audio engine after a media services reset", .info)
                return
            }
            log("Failed to rebuild the audio engine after a media services reset (attempt \(attempt)/\(restoreAttempts)), error: \(result)", .warning)

            guard attempt < restoreAttempts else { break }
            try? await Task.sleep(nanoseconds: restoreRetryDelayNanoseconds)

            // A failed restore leaves the engine unavailable. If the app has set an availability since,
            // it owns the engine again and must not be overridden.
            let current = await RTC.run { RTC.audioDeviceModule.engineAvailability.toLKType() }
            guard !current.isInputAvailable, !current.isOutputAvailable else {
                log("Engine availability was changed during the rebuild, leaving it to the app", .info)
                return
            }
        }

        log("Gave up rebuilding the audio engine after a media services reset. It stays unavailable until engine availability is set again", .error)
    }
}

#endif
