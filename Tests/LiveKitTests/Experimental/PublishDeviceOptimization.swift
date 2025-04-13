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

@testable import LiveKit
import XCTest

class PublishDeviceOptimizationTests: LKTestCase {
    // Default publish flow
    func testDefaultMicPublish() async throws {
        var sw = Stopwatch(label: "Test: Normal publish sequence")

        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
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
    func testNoVpMicPublish() async throws {
        // Turn off Apple's VP
        try! AudioManager.shared.setVoiceProcessingEnabled(false)

        var sw = Stopwatch(label: "Test: No-VP publish sequence")

        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
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
    func testConcurrentMicPublish() async throws {
        var swAll = Stopwatch(label: "Test: Concurrent publish sequence")

        try await withThrowingTaskGroup(of: Void.self) { group in

            group.addTask {
                var swAdm = Stopwatch(label: "Test: Start local recording")
                try AudioManager.shared.startLocalRecording()
                swAdm.split(label: "Start local recording complete")
                print(swAdm)
            }

            group.addTask {
                var swConnect = Stopwatch(label: "Test: Connect & publish mic")
                try await self.withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
                    swConnect.split(label: "Connected to room")
                    // Alias to Rooms
                    let room1 = rooms[0]
                    try await room1.localParticipant.setMicrophone(enabled: true)
                    swConnect.split(label: "Mic publish completed")
                }
                print(swConnect)
            }

            try await group.waitForAll()
        }

        swAll.split(label: "Sequence complete")
        print(swAll)

        print("Total time: \(swAll.total())")
    }
}
