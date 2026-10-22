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
@testable import LiveKit
import Testing

struct AudioSessionCategoryUpdateTests {
    private typealias Observer = AudioSessionEngineObserver

    private func needsUpdate(_ configuration: AudioSessionConfiguration, current: AudioSessionConfiguration) -> Bool {
        Observer.needsCategoryUpdate(configuration,
                                     category: current.category,
                                     mode: current.mode,
                                     options: current.categoryOptions)
    }

    @Test func unchangedConfigurationIsNotApplied() {
        #expect(!needsUpdate(.playAndRecordSpeaker, current: .playAndRecordSpeaker))
        #expect(!needsUpdate(.playAndRecordReceiverMedia, current: .playAndRecordReceiverMedia))
        #expect(!needsUpdate(.playback, current: .playback))
    }

    /// Voice Processing I/O switches the speaker preset's `.videoChat` to `.voiceChat`.
    @Test func voiceProcessingModeRewriteIsNotApplied() {
        let rewritten = AudioSessionConfiguration.playAndRecordSpeaker.copyWith(mode: .value(.voiceChat))
        #expect(!needsUpdate(.playAndRecordSpeaker, current: rewritten))
    }

    @Test func speakerPreferenceChangeIsApplied() {
        let rewritten = AudioSessionConfiguration.playAndRecordSpeaker.copyWith(mode: .value(.voiceChat))
        #expect(needsUpdate(.playAndRecordReceiver, current: rewritten))
        #expect(needsUpdate(.playAndRecordSpeaker, current: .playAndRecordReceiver))
        #expect(needsUpdate(.playAndRecordReceiverMedia, current: .playAndRecordSpeakerMedia))
    }

    @Test func voiceProcessingPathChangeIsApplied() {
        #expect(needsUpdate(.playAndRecordSpeakerMedia, current: .playAndRecordSpeaker))
        #expect(needsUpdate(.playAndRecordSpeaker, current: .playAndRecordSpeakerMedia))
    }

    @Test func categoryChangeIsApplied() {
        #expect(needsUpdate(.playAndRecordSpeaker, current: .playback))
        #expect(needsUpdate(.playback, current: .soloAmbient))
    }
}

#endif
