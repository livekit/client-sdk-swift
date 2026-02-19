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
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

final class TestEngineObserver: AudioEngineObserver, @unchecked Sendable {
    var next: (any LiveKit.AudioEngineObserver)?
    var shouldSucceed: Bool = true

    func engineWillEnable(_: AVAudioEngine, isPlayoutEnabled _: Bool, isRecordingEnabled _: Bool) -> Int {
        shouldSucceed ? 0 : -1
    }

    func engineDidStop(_: AVAudioEngine, isPlayoutEnabled _: Bool, isRecordingEnabled _: Bool) -> Int {
        shouldSucceed ? 0 : -1
    }
}

@Suite(.serialized, .tags(.audio)) struct AudioEngineObserverTests {
    // Error codes returned in an `AudioEngineObserver` should propagate through the WebRTC's AudioDeviceModule and
    // the SDK should throw in such cases for both device and manual rendering modes.
    @Test func observerFail() throws {
        let testObserver = TestEngineObserver()

        // Set test engine observer
        AudioManager.shared.set(engineObservers: [testObserver])

        // Test without enabling VP
        try AudioManager.shared.setVoiceProcessingEnabled(false)

        // First check
        #expect(!AudioManager.shared.isEngineRunning)

        #if os(iOS) || os(visionOS) || os(tvOS)
        try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playAndRecord)
        #endif

        testObserver.shouldSucceed = true

        // Attempt to start
        try AudioManager.shared.startLocalRecording()
        #expect(AudioManager.shared.isEngineRunning)

        testObserver.shouldSucceed = false

        // Stop
        #expect(throws: (any Error).self) { try AudioManager.shared.stopLocalRecording() }
        #expect(!AudioManager.shared.isEngineRunning)

        testObserver.shouldSucceed = true

        try AudioManager.shared.stopLocalRecording()
        #expect(!AudioManager.shared.isEngineRunning)

        testObserver.shouldSucceed = false

        // Attempt to start, should fail
        #expect(throws: (any Error).self) { try AudioManager.shared.startLocalRecording() }
        #expect(!AudioManager.shared.isEngineRunning)

        // Switch to manual mode
        try AudioManager.shared.setManualRenderingMode(true)

        testObserver.shouldSucceed = true

        // Attempt to start
        try AudioManager.shared.startLocalRecording()
        #expect(!AudioManager.shared.isEngineRunning)
    }
}
