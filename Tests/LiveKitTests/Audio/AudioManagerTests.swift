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

@preconcurrency import AVFoundation
@testable import LiveKit
import LiveKitWebRTC
import XCTest

class AudioManagerTests: LKTestCase {
    // Test legacy audio device module's startLocalRecording().
    func testStartLocalRecordingLegacyADM() async throws {
        // Use legacy ADM
        try AudioManager.set(audioDeviceModuleType: .platformDefault)

        // Ensure category
        #if os(iOS) || os(tvOS)
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoChat, options: [])
        #endif

        let recorder = try TestAudioRecorder()

        let audioTrack = LocalAudioTrack.createTrack()
        audioTrack.add(audioRenderer: recorder)

        // Start recording
        try AudioManager.shared.startLocalRecording()

        // Record for 5 seconds...
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)

        recorder.close()
        AudioManager.shared.stopRecording()

        // Play the recorded file...
        let player = try AVAudioPlayer(contentsOf: recorder.filePath)
        XCTAssertTrue(player.play(), "Failed to start audio playback")
        while player.isPlaying {
            try? await Task.sleep(nanoseconds: 1 * 100_000_000) // 10ms
        }
    }
}
