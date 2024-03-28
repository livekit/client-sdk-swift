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

class DelegateTests: XCTestCase {
    func testDelegate1() async throws {
        try await with2Rooms(delegate1: self) { _, _ in
            print("Rooms are ready...")
        }
    }
}

extension DelegateTests: RoomDelegate {
    func roomDidConnect(_ room: Room) {
        print("Room did connect, connectionState: \(room.connectionState)")
    }

    func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        XCTAssert(participant.sid != nil)
        XCTAssert(participant.identity != nil)
        print("participantDidDisconnect: \(String(describing: participant.sid))")
    }
}
