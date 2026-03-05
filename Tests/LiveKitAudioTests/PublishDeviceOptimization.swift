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

@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.audio, .e2e)) struct PublishDeviceOptimizationTests {
    // For testing remote server:
    let url: String? = nil
    let token: String? = nil

    // Default publish flow
    @Test func defaultMicPublish() async throws {
        var sw = Stopwatch(label: "Test: Normal publish sequence")

        let room1Opts = RoomTestingOptions(url: url, token: token, canPublish: true)
        try await TestEnvironment.withRooms([room1Opts]) { rooms in
            sw.split(label: "Connected to room")
            // Alias to Rooms
            let room1 = rooms[0]
            try await room1.localParticipant.setMicrophone(enabled: true)
            sw.split(label: "Did publish mic")
        }
        sw.split(label: "Sequence complete")
        print(sw)

        print("Total time: \(sw.total())")
    }

    // No-VP publish flow
    @Test func noVpMicPublish() async throws {
        // Turn off Apple's VP
        try AudioManager.shared.setVoiceProcessingEnabled(false)

        var sw = Stopwatch(label: "Test: No-VP publish sequence")

        let room1Opts = RoomTestingOptions(url: url, token: token, canPublish: true)
        try await TestEnvironment.withRooms([room1Opts]) { rooms in
            sw.split(label: "Connected to room")
            // Alias to Rooms
            let room1 = rooms[0]
            try await room1.localParticipant.setMicrophone(enabled: true)
            sw.split(label: "Did publish mic")
        }
        sw.split(label: "Sequence complete")
        print(sw)

        print("Total time: \(sw.total())")
    }

    // Concurrent device acquisition publish flow
    @Test func concurrentMicPublish() async throws {
        var sw = Stopwatch(label: "Test: Normal publish sequence")

        let room1Opts = RoomTestingOptions(url: url, token: token, enableMicrophone: true, canPublish: true)
        try await TestEnvironment.withRooms([room1Opts]) { rooms in
            sw.split(label: "Connected to room")
            // Alias to Rooms
            let room1 = rooms[0]
            // Mic should be already enabled at this point
            let isMicEnabled = room1.localParticipant.isMicrophoneEnabled()
            #expect(isMicEnabled, "Mic should be enabled at this point")
            sw.split(label: "Did publish mic")
        }
        sw.split(label: "Sequence complete")
        print(sw)

        print("Total time: \(sw.total())")
    }
}
