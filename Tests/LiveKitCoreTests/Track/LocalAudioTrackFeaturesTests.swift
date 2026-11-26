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

import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.media, .audio))
struct LocalAudioTrackFeaturesTests {
    private static let voiceFeatures: Set<Livekit_AudioTrackFeature> = [
        .tfEchoCancellation, .tfNoiseSuppression, .tfAutoGainControl,
    ]

    @Test func processingOptionsMapToFeatures() {
        #expect(AudioProcessingOptions().toFeatures() == Self.voiceFeatures)
        #expect(AudioProcessingOptions.noProcessing.toFeatures().isEmpty)

        let echoCancellationOnly = AudioProcessingOptions(
            echoCancellation: true,
            autoGainControl: false,
            noiseSuppression: false,
            highpassFilter: true,
            echoCancellationMode: .software,
        )
        #expect(echoCancellationOnly.toFeatures() == [.tfEchoCancellation])
    }

    @Test func featuresFollowCaptureOptionsUntilRuntimeChange() {
        let track = TestAudioTrack()
        #expect(track.features(publishOptions: nil) == Self.voiceFeatures)
        #expect(track.audioProcessing == track.captureOptions.audioProcessing)

        track.runtimeAudioProcessing.mutate { $0 = .noProcessing }

        #expect(track.audioProcessing == .noProcessing)
        #expect(track.features(publishOptions: nil).isEmpty)
        #expect(track.features(publishOptions: AudioPublishOptions(dtx: false)) == [.tfNoDtx])
    }

    @Test func acceptedRuntimeOptionsUpdateFeaturesAndNotifyPublication() async throws {
        let track = TestAudioTrack()
        let delegate = FeaturesDelegate()
        track.add(delegate: delegate)

        let result = try track.setAudioProcessingOptions(.noProcessing)
        #expect(result == .applied || result == .stored)
        #expect(track.audioProcessing == .noProcessing)
        #expect(track.features(publishOptions: nil).isEmpty)

        let deadline = Date().addingTimeInterval(5)
        while delegate.updateCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(delegate.updateCount == 1)
    }
}

private final class FeaturesDelegate: NSObject, LocalAudioTrackDelegateInternal, Sendable {
    private let updates = StateSync(0)

    var updateCount: Int { updates.copy() }

    func localAudioTrackDidUpdateAudioFeatures(_: LocalAudioTrack) {
        updates.mutate { $0 += 1 }
    }
}
