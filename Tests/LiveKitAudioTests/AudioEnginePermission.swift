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

@preconcurrency import AVFoundation
@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class AudioEnginePermissionTests: LKTestCase {
    #if os(iOS) || os(visionOS) || os(tvOS)
    // Check if audio engine will fail to start instead of crashing when `AVAudioSession.category` isn't
    // configured correctly. Only for non-macOS platforms.
    func testAudioSessionPermission() async throws {
        // Test without enabling VP
        try AudioManager.shared.setVoiceProcessingEnabled(false)

        // First check
        XCTAssertFalse(AudioManager.shared.isEngineRunning)

        // Set no engine observer
        AudioManager.shared.set(engineObservers: [])

        // Attempt to start, should fail
        XCTAssertThrowsError(try AudioManager.shared.startLocalRecording())
        XCTAssertFalse(AudioManager.shared.isEngineRunning)

        // Set audio session engine observers
        AudioManager.shared.set(engineObservers: [AudioSessionEngineObserver()])

        // Attempt to start
        try AudioManager.shared.startLocalRecording()
        XCTAssertTrue(AudioManager.shared.isEngineRunning)

        // Stop
        try AudioManager.shared.stopLocalRecording()
        XCTAssertFalse(AudioManager.shared.isEngineRunning)

        print("Category: \(AVAudioSession.sharedInstance().category)")
    }
    #endif
}
