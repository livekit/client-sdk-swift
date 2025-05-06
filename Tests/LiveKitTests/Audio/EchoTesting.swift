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

struct EchoTesterCase {
    let title: String
    let appleVp: Bool
    let captureOptions: AudioCaptureOptions?
}

struct EchoTestResult: CustomStringConvertible {
    let vad: Int
    let peak: Float

    var description: String {
        "VAD: \(vad), Peak: \(peak)"
    }
}

class EchoTests: LKTestCase {
    static let startTest = "start_test"
    static let stopTest = "stop_test"
    static let rmsKey = "lk.rms" // RMS level of the far-end signal
    static let peakKey = "lk.peak" // Peak level of the far-end signal
    static let vadKey = "lk.vad" // Number of speech events in the far-end signal

    func runEchoAgent(testCase: EchoTesterCase) async throws -> EchoTestResult {
        // No-VP
        try! AudioManager.shared.setVoiceProcessingEnabled(testCase.appleVp)

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

            var vadResult = 0
            try await room1.registerTextStreamHandler(for: Self.vadKey) { reader, _ in
                let resultString = try await reader.readAll()
                let result = Int(resultString) ?? 0
                if result > vadResult {
                    print("VAD \(vadResult) -> \(result)")
                    vadResult = result
                }
            }

            var peakResult: Float = 0
            try await room1.registerTextStreamHandler(for: Self.peakKey) { reader, _ in
                let resultString = try await reader.readAll()
                let result = Float(resultString) ?? 0
                if result > peakResult {
                    print("PEAK \(peakResult) -> \(result)")
                    peakResult = result
                }
            }

            // Enable mic
            try await room1.localParticipant.setMicrophone(enabled: true, captureOptions: testCase.captureOptions)

            // Bypass VP
            // AudioManager.shared.isVoiceProcessingBypassed = true

            // Start test
            _ = try await room1.localParticipant.performRpc(destinationIdentity: agentIdentity, method: Self.startTest, payload: "")

            // Sleep for 30 seconds...
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)

            return EchoTestResult(vad: vadResult, peak: peakResult)
        }
    }

    func testEchoAgent() async throws {
        let testCases = [
            EchoTesterCase(title: "Default", appleVp: true, captureOptions: nil),
            EchoTesterCase(title: "RTC VP Only", appleVp: false, captureOptions: AudioCaptureOptions(echoCancellation: true,
                                                                                                     autoGainControl: true,
                                                                                                     noiseSuppression: true,
                                                                                                     highpassFilter: true)),
        ]

        for testCase in testCases {
            let result = try await runEchoAgent(testCase: testCase)
            print("Result: \(testCase.title) \(result)")
        }
    }
}
