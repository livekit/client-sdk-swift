/*
 * Copyright 2024 LiveKit
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

extension XCTestCase {
    func testUrl() -> String {
        ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"] ?? "ws://localhost:7880"
    }

    func testToken(for room: String, identity: String) throws -> String {
        let apiKey = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_API_KEY"] ?? "devkey"
        let apiSecret = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_API_SECRET"] ?? "secret"

        let tokenGenerator = TokenGenerator(apiKey: apiKey,
                                            apiSecret: apiSecret,
                                            identity: identity)

        tokenGenerator.videoGrant = VideoGrant(room: room,
                                               roomJoin: true,
                                               canPublish: true)
        return try tokenGenerator.sign()
    }

    // Set up 2 Rooms
    func with2Rooms(_ block: @escaping (Room, Room) async throws -> Void) async throws {
        // Turn on stats
        let roomOptions = RoomOptions(reportRemoteTrackStatistics: true)

        let room1 = Room(roomOptions: roomOptions)
        let room2 = Room(roomOptions: roomOptions)

        let url = testUrl()

        let roomName = UUID().uuidString

        let token1 = try testToken(for: roomName, identity: "identity01")
        try await room1.connect(url: url, token: token1)

        let token2 = try testToken(for: roomName, identity: "identity02")
        try await room2.connect(url: url, token: token2)

        let observerToken = try testToken(for: roomName, identity: "observer")
        print("Observer token: \(observerToken) for room: \(roomName)")

        let room1ParticipantCountIs2 = expectation(description: "Room1 Participant count is 2")
        room1ParticipantCountIs2.assertForOverFulfill = false

        let room2ParticipantCountIs2 = expectation(description: "Room2 Participant count is 2")
        room2ParticipantCountIs2.assertForOverFulfill = false

        let watchRoom1 = room1.objectWillChange.sink { _ in
            if room1.allParticipants.count == 2 {
                room1ParticipantCountIs2.fulfill()
            }
        }

        let watchRoom2 = room2.objectWillChange.sink { _ in
            if room2.allParticipants.count == 2 {
                room2ParticipantCountIs2.fulfill()
            }
        }

        // Wait until both room's participant count is 2
        await fulfillment(of: [room1ParticipantCountIs2, room2ParticipantCountIs2], timeout: 30)

        try await block(room1, room2)
        await room1.disconnect()
        await room2.disconnect()
        watchRoom1.cancel()
        watchRoom2.cancel()
    }
}
