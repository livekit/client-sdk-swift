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

#if os(iOS) || os(visionOS) || os(tvOS) || targetEnvironment(macCatalyst)
@preconcurrency import AVFoundation
@testable import LiveKit
import LiveKitWebRTC
import XCTest

class USBAudioTests: LKTestCase {
    func testInputDevice() async throws {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try AudioManager.shared.setVoiceProcessingEnabled(false)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)

        print("Current category: \(session.category), mode: \(session.mode)")

        // Print inputs
        if let inputs = session.availableInputs {
            print("Initial available inputs (\(inputs.count) total):")
            for input in inputs {
                print("Input: \(input.portName) (type: \(input.portType))")
            }
        }

        // Find external mic
        let externalInput = session.availableInputs?.first(where: { $0.portType == .headsetMic })
        guard let externalInput else {
            XCTFail("External input not found, external device required for this test")
            return
        }

        print("External input: \(externalInput.portName)")

        // Set external mic
        try session.setPreferredInput(externalInput)
        print("Preferred input: \(String(describing: session.preferredInput))")
        XCTAssert(session.preferredInput != nil, "Preferred input not set")

        // Connect to a Room
        // url: "ws://192.168.1.3:7880"
        try await withRooms([RoomTestingOptions(canPublish: true, canSubscribe: true)]) { rooms in
            // Alias to Room
            let room1 = rooms[0]

            // Publish mic
            try await room1.localParticipant.setMicrophone(enabled: true)

            // Wait for 3 seconds...
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)

            // Check if preferred input is still same external input
            print("Preferred input: \(String(describing: session.preferredInput))")
            XCTAssert(session.preferredInput?.uid == externalInput.uid, "Preferred input has changed")
        }
    }
}
#endif
