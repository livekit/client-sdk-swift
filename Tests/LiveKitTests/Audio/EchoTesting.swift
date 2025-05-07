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

class EchoTests: LKTestCase {
    static let startTest = "start_test"
    static let stopTest = "stop_test"
    static let rmsKey = "lk.rms" // RMS level of the far-end signal
    static let peakKey = "lk.peak" // Peak level of the far-end signal
    static let vadKey = "lk.vad" // Number of speech events in the far-end signal

    struct TestCase {
        let title: String
        let enableAppleVp: Bool
        let captureOptions: AudioCaptureOptions?
    }

    struct TestResult: CustomStringConvertible {
        let vadCount: Int
        let maxPeak: Float

        var description: String {
            "VAD: \(vadCount), Peak: \(maxPeak)"
        }
    }

    // Actor to safely manage state across concurrent contexts
    actor TestStateActor {
        private(set) var vadResult: Int = 0
        private(set) var peakResult: Float = -120.0

        func updateVad(_ newValue: Int) {
            if newValue > vadResult {
                print("Updating VAD \(vadResult) -> \(newValue)")
                vadResult = newValue
            }
        }

        func updatePeak(_ newValue: Float) {
            if newValue > peakResult {
                print("Updating PEAK \(peakResult) -> \(newValue)")
                peakResult = newValue
            }
        }

        func getResults() -> TestResult {
            TestResult(vadCount: vadResult, maxPeak: peakResult)
        }
    }

    func runEchoAgent(testCase: TestCase) async throws -> TestResult {
        // No-VP
        try! AudioManager.shared.setVoiceProcessingEnabled(testCase.enableAppleVp)
        // Bypass VP
        AudioManager.shared.isVoiceProcessingBypassed = !testCase.enableAppleVp

        return try await withRooms([RoomTestingOptions(canPublish: true, canPublishData: true, canSubscribe: true)]) { rooms in
            // Alias to Room
            let room1 = rooms[0]

            // Sleep for 3 seconds for agent to join...
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)

            // Find agent
            let echoAgent: RemoteParticipant? = room1.remoteParticipants.values.first { $0.kind == .agent }
            XCTAssert(echoAgent != nil, "Agent participant not found") // Echo agent must be running
            guard let agentIdentity = echoAgent?.identity else {
                XCTFail("Echo agent's identity is nil")
                fatalError()
            }

            let state = TestStateActor()

            try await room1.registerTextStreamHandler(for: Self.vadKey) { [state] reader, _ in
                let resultString = try await reader.readAll()
                guard let result = Int(resultString) else { return }
                await state.updateVad(result)
            }

            try await room1.registerTextStreamHandler(for: Self.peakKey) { [state] reader, _ in
                let resultString = try await reader.readAll()
                guard let result = Float(resultString) else { return }
                await state.updatePeak(result)
            }

            // Enable mic
            try await room1.localParticipant.setMicrophone(enabled: true, captureOptions: testCase.captureOptions)

            // Sleep for 1 seconds...
            try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)

            // Check Apple VP
            XCTAssert(testCase.enableAppleVp == AudioManager.shared.isVoiceProcessingEnabled)
            XCTAssert(testCase.enableAppleVp != AudioManager.shared.isVoiceProcessingBypassed)

            // Check APM is enabled
            let apmConfig = RTC.audioProcessingModule.config
            print("APM Config: \(apmConfig.toDebugString()))")
            XCTAssert((testCase.captureOptions?.echoCancellation ?? false) == apmConfig.isEchoCancellationEnabled)
            XCTAssert((testCase.captureOptions?.autoGainControl ?? false) == apmConfig.isAutoGainControl1Enabled)
            XCTAssert((testCase.captureOptions?.noiseSuppression ?? false) == apmConfig.isNoiseSuppressionEnabled)
            XCTAssert((testCase.captureOptions?.highpassFilter ?? false) == apmConfig.isHighpassFilterEnabled)

            // Start test
            _ = try await room1.localParticipant.performRpc(destinationIdentity: agentIdentity, method: Self.startTest, payload: "")

            // Sleep for 30 seconds...
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)

            // Stop test
            _ = try await room1.localParticipant.performRpc(destinationIdentity: agentIdentity, method: Self.stopTest, payload: "")

            // Get final results from the actor
            return await state.getResults()
        }
    }

    func testEchoAgent() async throws {
        let defaultTestCase = TestCase(title: "Default", enableAppleVp: true, captureOptions: nil)
        let allCaptureOptions = AudioCaptureOptions(echoCancellation: true,
                                                    autoGainControl: true,
                                                    noiseSuppression: true,
                                                    highpassFilter: true)
        let testCases = [
            TestCase(title: "None", enableAppleVp: false, captureOptions: nil),
            TestCase(title: "RTC VP Only", enableAppleVp: false, captureOptions: allCaptureOptions),
            TestCase(title: "Both", enableAppleVp: true, captureOptions: allCaptureOptions),
        ]

        // Run default test first
        print("Running Default test case...")
        let defaultResult = try await runEchoAgent(testCase: defaultTestCase)
        print("Result: \(defaultTestCase.title) \(defaultResult)")

        print("\n======= Test Results Summary =======")
        print("Default: \(defaultResult)")

        // Run other test cases and compare with default
        for testCase in testCases {
            let result = try await runEchoAgent(testCase: testCase)
            print("Result: \(testCase.title) \(result)")

            let vadDiff = result.vadCount - defaultResult.vadCount
            let peakDiff = result.maxPeak - defaultResult.maxPeak

            print("\(testCase.title): \(result)")
            print("  Compared to Default:")
            print("  - VAD difference: \(vadDiff > 0 ? "+" : "")\(vadDiff) events")
            print("  - Peak difference: \(peakDiff > 0 ? "+" : "")\(String(format: "%.2f", peakDiff)) dB")

            // Optional basic analysis
            let vadPercentChange = defaultResult.vadCount > 0 ? Float(vadDiff) / Float(defaultResult.vadCount) * 100 : 0
            print("  - VAD % change: \(String(format: "%.1f", vadPercentChange))%")
        }
        print("===================================")
    }
}
