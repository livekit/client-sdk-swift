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

import AVFoundation
import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class TestTrack: LocalAudioTrack, @unchecked Sendable {
    init() {
        let source = RTC.createAudioSource(nil)
        let _track = RTC.createAudioTrack(source: source)
        super.init(name: "test_audio_track", source: .microphone, track: _track, reportStatistics: false, captureOptions: AudioCaptureOptions())
    }

    override func startCapture() async throws {
        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.0 ... 1.0) * 1_000_000))
    }

    override func stopCapture() async throws {
        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.0 ... 1.0) * 1_000_000))
    }
}

@Suite(.tags(.media))
struct TrackTests {
    #if os(iOS) || os(visionOS) || os(tvOS)
    @Test func concurrentStartStop() async throws {
        // Set config func to watch state changes.
        AudioManager.shared.customConfigureAudioSessionFunc = { newState, _ in
            print("localTracksCount: \(newState.localTracksCount)")
            if newState.localTracksCount < 0 { Issue.record("localTracksCount should never be negative") }
            if newState.localTracksCount > 2 { Issue.record("localTracksCount should never higher than 2 in this test") }
        }

        let track1 = TestTrack()
        let track2 = TestTrack()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 1000 {
                group.addTask {
                    let track = Bool.random() ? track1 : track2
                    if Bool.random() {
                        try await track.start()
                    } else {
                        try await track.stop()
                    }
                }
            }

            try await group.waitForAll()
        }

        try await track1.stop()
        try await track2.stop()

        AudioManager.shared.customConfigureAudioSessionFunc = nil

        #expect(AudioManager.shared._state.localTracksCount == 0, "localTracksCount should be 0")
    }
    #endif
}
