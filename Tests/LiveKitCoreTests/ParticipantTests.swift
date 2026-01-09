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

class ParticipantTests: LKTestCase {
    func testLocalParticipantIdentity() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            // Alias to Room
            let room1 = rooms[0]

            XCTAssert(room1.localParticipant.identity != nil, "LocalParticipant's identity is nil")

            print("room1.localParticipant.identity: \(String(describing: room1.localParticipant.identity))")
        }
    }

    func testRemoteParticipants() async throws {
        try await withRooms([RoomTestingOptions(), RoomTestingOptions(), RoomTestingOptions()]) { rooms in
            // Alias to Room
            let room1 = rooms[0]
            let room2 = rooms[1]
            let room3 = rooms[2]

            XCTAssert(room1.remoteParticipants.count == 2, "Remote participant count must be 2")
            XCTAssert(room2.remoteParticipants.count == 2, "Remote participant count must be 2")
            XCTAssert(room3.remoteParticipants.count == 2, "Remote participant count must be 2")

            print("room1.remoteParticipants: \(String(describing: room1.remoteParticipants))")
            print("room2.remoteParticipants: \(String(describing: room2.remoteParticipants))")
            print("room2.remoteParticipants: \(String(describing: room3.remoteParticipants))")
        }
    }
}
