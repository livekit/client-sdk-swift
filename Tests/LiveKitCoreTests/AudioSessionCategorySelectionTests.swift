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
import Foundation
@testable import LiveKit
import Testing

struct AudioSessionCategorySelectionTests {
    private typealias Observer = AudioSessionEngineObserver

    private func state(_ requirement: SessionRequirement,
                       hasRecorded: Bool = false,
                       speaker: Bool = true,
                       platformVoiceProcessing: Bool = true) -> Observer.State
    {
        var state = Observer.State()
        state.isSpeakerOutputPreferred = speaker
        state.isPlatformVoiceProcessingExpected = platformVoiceProcessing
        state.hasRecorded = hasRecorded
        if requirement != .none {
            state.sessionRequirements = [UUID(): requirement]
        }
        return state
    }

    @Test func playoutOnlyUsesPlayback() {
        #expect(Observer.selectConfiguration(state: state(.playbackOnly)) == .playback)
    }

    @Test func recordingUsesPlayAndRecord() {
        #expect(Observer.selectConfiguration(state: state(.playbackAndRecording)) == .playAndRecordSpeaker)
        #expect(Observer.selectConfiguration(state: state(.playbackAndRecording, speaker: false)) == .playAndRecordReceiver)
    }

    /// Muting the mic drops the recording requirement; the category must not
    /// fall back to `.playback`, which would tear down Voice Processing I/O.
    @Test func mutingAfterRecordingKeepsPlayAndRecord() {
        #expect(Observer.selectConfiguration(state: state(.playbackOnly, hasRecorded: true)) == .playAndRecordSpeaker)
    }

    /// Software voice processing has no compensating loudness stage, so the
    /// media-tuned presets are used instead of the chat modes.
    @Test func softwareVoiceProcessingUsesMediaPresets() {
        #expect(Observer.selectConfiguration(state: state(.playbackAndRecording, platformVoiceProcessing: false)) == .playAndRecordSpeakerMedia)
        #expect(Observer.selectConfiguration(state: state(.playbackAndRecording, speaker: false, platformVoiceProcessing: false)) == .playAndRecordReceiverMedia)
    }

    // MARK: - Sticky bit lifecycle

    /// Drives the observer without touching `AVAudioSession`, so only the
    /// bookkeeping in `updateRequirements` is exercised.
    private func makeObserver() -> (Observer, AVAudioEngine) {
        let observer = Observer()
        observer.isAutomaticConfigurationEnabled = false
        return (observer, AVAudioEngine())
    }

    @Test func stickyBitSurvivesMuting() {
        let (observer, engine) = makeObserver()
        _ = observer.engineWillEnable(engine, isPlayoutEnabled: true, isRecordingEnabled: true)
        #expect(observer._state.hasRecorded)

        // Mute: the engine keeps playing out but stops recording.
        _ = observer.engineDidDisable(engine, isPlayoutEnabled: true, isRecordingEnabled: false)
        #expect(observer._state.hasRecorded)
    }

    @Test func stickyBitClearsWhenTheEngineStops() {
        let (observer, engine) = makeObserver()
        _ = observer.engineWillEnable(engine, isPlayoutEnabled: true, isRecordingEnabled: true)
        _ = observer.engineDidDisable(engine, isPlayoutEnabled: false, isRecordingEnabled: false)
        #expect(!observer._state.hasRecorded)
    }

    /// An externally held playout requirement (a prepared `SoundPlayer` sound)
    /// outlives the call and must not pin the category to `.playAndRecord`.
    @Test func externalPlayoutRequirementDoesNotPinTheStickyBit() throws {
        let (observer, engine) = makeObserver()
        let handle = try observer.acquire(requirement: .playbackOnly)
        defer { try? handle.release() }

        _ = observer.engineWillEnable(engine, isPlayoutEnabled: true, isRecordingEnabled: true)
        #expect(observer._state.hasRecorded)

        _ = observer.engineDidDisable(engine, isPlayoutEnabled: false, isRecordingEnabled: false)
        #expect(!observer._state.hasRecorded)
        #expect(Observer.selectConfiguration(state: observer._state.copy()) == .playback)
    }

    /// An external `.recording` requirement (e.g. recording-always-prepared
    /// mode) also engages the sticky bit; releasing it mid-call keeps
    /// `.playAndRecord` until the engine stops.
    @Test func externalRecordingRequirementSticksUntilTheEngineStops() throws {
        let (observer, engine) = makeObserver()
        _ = observer.engineWillEnable(engine, isPlayoutEnabled: true, isRecordingEnabled: false)
        #expect(!observer._state.hasRecorded)

        let handle = try observer.acquire(requirement: .playbackAndRecording)
        #expect(observer._state.hasRecorded)

        try handle.release()
        #expect(observer._state.hasRecorded)
        #expect(Observer.selectConfiguration(state: observer._state.copy()) == .playAndRecordSpeaker)

        _ = observer.engineDidDisable(engine, isPlayoutEnabled: false, isRecordingEnabled: false)
        #expect(!observer._state.hasRecorded)
    }
}

#endif
