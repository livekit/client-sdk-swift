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

import AVFoundation
@testable import LiveKit
import LiveKitWebRTC
import XCTest

class AudioEngineTests: XCTestCase {
    override class func setUp() {
        LiveKitSDK.setLoggerStandardOutput()
        RTCSetMinDebugLogLevel(.info)
    }

    override func tearDown() async throws {}

    // Test if mic is authorized. Only works on device.
    func testMicAuthorized() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != .authorized {
            let result = await AVCaptureDevice.requestAccess(for: .audio)
            XCTAssert(result)
        }

        XCTAssert(status == .authorized)
    }

    // Test start generating local audio buffer without joining to room.
    func testPrejoinLocalAudioBuffer() async throws {
        // Set up expectation...
        let didReceiveAudioFrame = expectation(description: "Did receive audio frame")
        didReceiveAudioFrame.assertForOverFulfill = false

        // Start watching for audio frame...
        let audioFrameWatcher = AudioTrackWatcher(id: "notifier01") { _ in
            didReceiveAudioFrame.fulfill()
        }

        let localMicTrack = LocalAudioTrack.createTrack()
        // Attach audio frame watcher...
        localMicTrack.add(audioRenderer: audioFrameWatcher)

        Task.detached {
            print("Starting audio track in 3 seconds...")
            try? await Task.sleep(for: .seconds(3))
            AudioManager.shared.startRecording()
        }

        // Wait for audio frame...
        print("Waiting for first audio frame...")
        await fulfillment(of: [didReceiveAudioFrame], timeout: 10)

        // Remove audio frame watcher...
        localMicTrack.remove(audioRenderer: audioFrameWatcher)
    }

    // Test the manual rendering mode (no-device mode) of AVAudioEngine based AudioDeviceModule.
    // In manual rendering, no device access will be initialized such as mic and speaker.
    func testManualRenderingMode() async throws {
        // Attach sin wave generator when engine requests input node...
        // inputMixerNode will automatically convert to RTC's internal format (int16).
        // AVAudioEngine.attach() retains the node.
        AudioManager.shared.onEngineWillConnectInput = { _, engine, inputMixerNode in
            let sin = SineWaveSourceNode()
            engine.attach(sin)
            engine.connect(sin, to: inputMixerNode, format: nil)
        }

        // Set manual rendering mode...
        AudioManager.shared.isManualRenderingMode = true

        // Check if manual rendering mode is set...
        let isManualRenderingMode = AudioManager.shared.isManualRenderingMode
        print("manualRenderingMode: \(isManualRenderingMode)")
        XCTAssert(isManualRenderingMode)

        // Start rendering...
        AudioManager.shared.startRecording()

        // Render for 10 seconds...
        try? await Task.sleep(for: .seconds(10))
    }
}
