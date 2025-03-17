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

class PreConnectAudioBufferTests: LKTestCase {
    func testRoomDidConnectSetsParticipantAttribute() async throws {
        let attributeSetExpectation = expectation(description: "Participant attribute set")

        class AttributeDelegate: RoomDelegate {
            let expectation: XCTestExpectation
            var attributeValue: String?

            init(expectation: XCTestExpectation) {
                self.expectation = expectation
            }

            func room(_: Room, participant: Participant, didUpdateAttributes _: [String: String]) {
                if let value = participant.attributes[PreConnectAudioBuffer.attributeKey] {
                    attributeValue = value
                    expectation.fulfill()
                }
            }
        }

        let delegate = AttributeDelegate(expectation: attributeSetExpectation)

        try await withRooms([RoomTestingOptions(delegate: delegate)]) { rooms in
            let room = rooms[0]
            let buffer = PreConnectAudioBuffer(room: room)

            buffer.roomDidConnect(room)

            await self.fulfillment(of: [attributeSetExpectation], timeout: 5)

            XCTAssertEqual(delegate.attributeValue, "true")
            XCTAssertEqual(room.localParticipant.attributes[PreConnectAudioBuffer.attributeKey], "true")
        }
    }

    func testRemoteDidSubscribeTrackSendsAudioData() async throws {
        let receiveExpectation = expectation(description: "Receives audio data")

        try await withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublish: true, canPublishData: true)]) { rooms in
            let subscriberRoom = rooms[0]
            let publisherRoom = rooms[1]

            try await subscriberRoom.registerByteStreamHandler(for: PreConnectAudioBuffer.dataTopic) { reader, participant in
                XCTAssertEqual(participant, publisherRoom.localParticipant.identity)
                do {
                    let data = try await reader.readAll()
                    XCTAssertFalse(data.isEmpty, "Received audio data should not be empty")
                    receiveExpectation.fulfill()
                } catch {
                    XCTFail("Read failed: \(error.localizedDescription)")
                }
            }

            let buffer = PreConnectAudioBuffer(room: publisherRoom)

            try await buffer.startRecording()
            try await Task.sleep(nanoseconds: NSEC_PER_SEC / 2)

            let publication = LocalTrackPublication(info: Livekit_TrackInfo(), participant: rooms[0].localParticipant)
            buffer.room(publisherRoom, participant: publisherRoom.localParticipant, remoteDidSubscribeTrack: publication)

            await self.fulfillment(of: [receiveExpectation], timeout: 10)
        }
    }
}
