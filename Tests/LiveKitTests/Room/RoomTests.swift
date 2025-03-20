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

class RoomTests: LKTestCase {
    func testRoomProperties() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            // Alias to Room
            let room1 = rooms[0]

            // SID
            let sid = try await room1.sid()
            print("Room.sid(): \(String(describing: sid))")
            XCTAssert(sid.stringValue.starts(with: "RM_"))

            // creationTime
            XCTAssert(room1.creationTime != nil)
            print("Room.creationTime: \(String(describing: room1.creationTime))")
        }
    }

    func testParticipantCleanUp() async throws {
        // Create 2 Rooms
        try await withRooms([RoomTestingOptions(delegate: self), RoomTestingOptions(delegate: self)]) { _ in
            // Nothing to do here
        }
    }

    func testSendDataPacket() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            let expectDataPacket = self.expectation(description: "Should send data packet")

            let mockDataChannel = MockDataChannelPair { packet in
                XCTAssertEqual(packet.participantIdentity, room.localParticipant.identity?.stringValue ?? "")
                expectDataPacket.fulfill()
            }
            room.publisherDataChannel = mockDataChannel

            try await room.send(dataPacket: Livekit_DataPacket())

            await self.fulfillment(of: [expectDataPacket], timeout: 5)
        }
    }
}

extension RoomTests: RoomDelegate {
    func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        print("participantDidDisconnect: \(participant)")
        // Check issue: https://github.com/livekit/client-sdk-swift/issues/300
        // participant.identity is null in participantDidDisconnect delegate
        XCTAssert(participant.identity != nil, "participant.identity is nil in participantDidDisconnect delegate")
    }
}
