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

class RoomDelegates: XCTestCase {
    func testDelegate1() async throws {
        let exp = expectation(description: "")
        exp.assertForOverFulfill = false

        let delegateObserver = RoomDelegateObserver()
        delegateObserver.onDidPublishTrack = { exp.fulfill() }

        try await with2Rooms(delegate1: delegateObserver) { _, _ in
            print("Rooms are ready...")
            // Wait for track...
            print("Waiting for publish track...")
            await self.fulfillment(of: [exp], timeout: 30)
        }
    }
}

class RoomDelegateObserver: RoomDelegate {
    var onDidPublishTrack: (() -> Void)?

    func roomDidConnect(_ room: Room) {
        print("Room did connect, connectionState: \(room.connectionState)")
        // Test of calling instance methods within the delegate
        Task {
            try await room.localParticipant.setMicrophone(enabled: true)
        }
    }

    func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        XCTAssert(participant.sid != nil)
        XCTAssert(participant.identity != nil)
        print("participantDidDisconnect: \(String(describing: participant.sid))")
    }

    func room(_: Room, participant _: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        print("didPublishTrack: \(publication)")
        onDidPublishTrack?()
    }
}
