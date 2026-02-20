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

class RoomParticipantTests: LKTestCase, @unchecked Sendable {
    // MARK: - Participant Connected Event

    private var participantConnectedExpectation: XCTestExpectation?
    private var connectedParticipantIdentity: Participant.Identity?

    func testParticipantConnectedEventFires() async throws {
        participantConnectedExpectation = expectation(description: "participantDidConnect should fire")

        // Room 1 connects first with delegate, then room 2 joins
        let room1 = Room(delegate: self, connectOptions: ConnectOptions())
        let roomName = UUID().uuidString

        let token1 = try liveKitServerToken(
            for: roomName,
            identity: "observer",
            canPublish: false,
            canPublishData: false,
            canPublishSources: [],
            canSubscribe: true
        )

        try await room1.connect(url: liveKitServerUrl(), token: token1)

        // Now connect a second room
        let room2 = Room(connectOptions: ConnectOptions())
        let token2 = try liveKitServerToken(
            for: roomName,
            identity: "joiner",
            canPublish: false,
            canPublishData: false,
            canPublishSources: [],
            canSubscribe: false
        )

        try await room2.connect(url: liveKitServerUrl(), token: token2)

        await fulfillment(of: [participantConnectedExpectation!], timeout: 10)
        XCTAssertEqual(connectedParticipantIdentity?.stringValue, "joiner")

        // Cleanup
        await room1.disconnect()
        await room2.disconnect()
    }

    // MARK: - Participant Permissions

    func testLocalParticipantPermissions() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true, canPublishData: true, canSubscribe: true)]) { rooms in
            let perms = rooms[0].localParticipant.permissions
            XCTAssertTrue(perms.canPublish)
            XCTAssertTrue(perms.canPublishData)
            XCTAssertTrue(perms.canSubscribe)
        }
    }

    func testLocalParticipantRestrictedPermissions() async throws {
        try await withRooms([RoomTestingOptions(canPublish: false, canPublishData: false, canSubscribe: false)]) { rooms in
            let perms = rooms[0].localParticipant.permissions
            XCTAssertFalse(perms.canPublish)
            XCTAssertFalse(perms.canPublishData)
            XCTAssertFalse(perms.canSubscribe)
        }
    }

    // MARK: - Remote Participant Properties

    func testRemoteParticipantIdentityMatchesToken() async throws {
        try await withRooms([RoomTestingOptions(), RoomTestingOptions()]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            // Room1's remote participant should be room2's local participant
            let remote = room1.remoteParticipants.values.first
            XCTAssertNotNil(remote)
            XCTAssertEqual(remote?.identity, room2.localParticipant.identity)
        }
    }

    func testRemoteParticipantHasSid() async throws {
        try await withRooms([RoomTestingOptions(), RoomTestingOptions()]) { rooms in
            let remote = rooms[0].remoteParticipants.values.first
            XCTAssertNotNil(remote?.sid)
        }
    }
}

extension RoomParticipantTests: RoomDelegate {
    func room(_: Room, participantDidConnect participant: RemoteParticipant) {
        connectedParticipantIdentity = participant.identity
        participantConnectedExpectation?.fulfill()
    }
}
