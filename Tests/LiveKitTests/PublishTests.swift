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

import Combine
@testable import LiveKit
import XCTest

class PublishTests: XCTestCase {
    let room1 = Room()
    let room2 = Room()

    var watchRoom1: AnyCancellable?
    var watchRoom2: AnyCancellable?

    override func setUp() async throws {
        let url = testUrl()

        let token1 = try testToken(for: "room01", identity: "identity01")
        try await room1.connect(url: url, token: token1)

        let token2 = try testToken(for: "room01", identity: "identity02")
        try await room2.connect(url: url, token: token2)

        let room1ParticipantCountIs2 = expectation(description: "Room1 Participant count is 2")
        room1ParticipantCountIs2.assertForOverFulfill = false

        let room2ParticipantCountIs2 = expectation(description: "Room2 Participant count is 2")
        room2ParticipantCountIs2.assertForOverFulfill = false

        watchRoom1 = room1.objectWillChange.sink { _ in
            if self.room1.allParticipants.count == 2 {
                room1ParticipantCountIs2.fulfill()
            }
        }

        watchRoom2 = room2.objectWillChange.sink { _ in
            if self.room2.allParticipants.count == 2 {
                room2ParticipantCountIs2.fulfill()
            }
        }

        // Wait until both room's participant count is 2
        await fulfillment(of: [room1ParticipantCountIs2, room2ParticipantCountIs2], timeout: 30)
    }

    override func tearDown() async throws {
        await room1.disconnect()
        await room2.disconnect()
        watchRoom1?.cancel()
        watchRoom2?.cancel()
    }

    func testResolveSid() async throws {
        XCTAssert(room1.connectionState == .connected)

        let sid = try await room1.sid()
        print("Room.sid(): \(String(describing: sid))")
        XCTAssert(sid.stringValue.starts(with: "RM_"))
    }

    func testConcurrentMicPublish() async throws {
        // Lock
        struct State {
            var firstMicPublication: LocalTrackPublication?
        }

        let _state = StateSync(State())

        // Run Tasks concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 1 ... 100 {
                group.addTask {
                    let result = try await self.room1.localParticipant.setMicrophone(enabled: true)

                    if let result {
                        _state.mutate {
                            if let firstMicPublication = $0.firstMicPublication {
                                XCTAssert(result == firstMicPublication, "Duplicate mic track has been published")
                            } else {
                                $0.firstMicPublication = result
                                print("Did publish first mic track: \(String(describing: result))")
                            }
                        }
                    }
                }
            }

            try await group.waitForAll()
        }
    }
}
