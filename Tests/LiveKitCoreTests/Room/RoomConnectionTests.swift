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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class RoomConnectionTests: LKTestCase, @unchecked Sendable {
    // MARK: - Connection State

    func testRoomIsConnectedAfterJoin() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            XCTAssertEqual(room.connectionState, .connected)
        }
    }

    func testRoomHasServerVersion() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            XCTAssertNotNil(room.serverVersion)
        }
    }

    func testRoomHasCreationTime() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            XCTAssertNotNil(room.creationTime)
        }
    }

    func testRoomHasName() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            XCTAssertNotNil(room.name)
            XCTAssertFalse(room.name!.isEmpty)
        }
    }

    func testRoomSidStartsWithRM() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let sid = try await room.sid()
            XCTAssertTrue(sid.stringValue.starts(with: "RM_"))
        }
    }

    // MARK: - Disconnect

    func testRoomDisconnectReturnsToDisconnectedState() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            XCTAssertEqual(room.connectionState, .connected)
            await room.disconnect()
            XCTAssertEqual(room.connectionState, .disconnected)
        }
    }

    func testRoomDisconnectClearsRemoteParticipants() async throws {
        try await withRooms([RoomTestingOptions(), RoomTestingOptions()]) { rooms in
            let room1 = rooms[0]
            XCTAssertEqual(room1.remoteParticipants.count, 1)
            await room1.disconnect()
            XCTAssertEqual(room1.remoteParticipants.count, 0)
        }
    }

    // MARK: - Local Participant

    func testLocalParticipantHasIdentity() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            XCTAssertNotNil(room.localParticipant.identity)
        }
    }

    func testLocalParticipantHasSid() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            XCTAssertNotNil(room.localParticipant.sid)
        }
    }

    // MARK: - Multi-Participant Discovery

    func testTwoParticipantDiscovery() async throws {
        try await withRooms([RoomTestingOptions(), RoomTestingOptions()]) { rooms in
            XCTAssertEqual(rooms[0].remoteParticipants.count, 1)
            XCTAssertEqual(rooms[1].remoteParticipants.count, 1)
        }
    }

    func testThreeParticipantDiscovery() async throws {
        try await withRooms([
            RoomTestingOptions(),
            RoomTestingOptions(),
            RoomTestingOptions(),
        ]) { rooms in
            XCTAssertEqual(rooms[0].remoteParticipants.count, 2)
            XCTAssertEqual(rooms[1].remoteParticipants.count, 2)
            XCTAssertEqual(rooms[2].remoteParticipants.count, 2)
        }
    }

    func testRemoteParticipantHasIdentity() async throws {
        try await withRooms([RoomTestingOptions(), RoomTestingOptions()]) { rooms in
            let remote = rooms[0].remoteParticipants.values.first
            XCTAssertNotNil(remote)
            XCTAssertNotNil(remote?.identity)
        }
    }

    // MARK: - Participant Disconnect Delegate

    private var participantDisconnectExpectation: XCTestExpectation?

    func testParticipantDisconnectDelegateFiresWithIdentity() async throws {
        participantDisconnectExpectation = expectation(description: "participantDidDisconnect should fire")

        try await withRooms([RoomTestingOptions(delegate: self), RoomTestingOptions()]) { rooms in
            // Room 2 disconnects, room 1 should get the delegate callback
            await rooms[1].disconnect()
            await self.fulfillment(of: [self.participantDisconnectExpectation!], timeout: 10)
        }
    }
}

extension RoomConnectionTests: RoomDelegate {
    func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        XCTAssertNotNil(participant.identity, "identity should not be nil in participantDidDisconnect")
        participantDisconnectExpectation?.fulfill()
    }
}
