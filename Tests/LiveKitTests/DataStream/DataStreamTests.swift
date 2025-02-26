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

import LiveKit
import XCTest

class DataStreamTests: LKTestCase {
    func testStreamText() async throws {
        let receiveExpectation = expectation(description: "Receives stream chunk")
        let topic = "some-topic"
        let testChunk = "Hello world!"

        try await withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let room0 = rooms[0]
            let room1 = rooms[1]

            try await room0.registerTextStreamHandler(for: topic) { reader, participant in
                XCTAssertEqual(participant, room1.localParticipant.identity)
                do {
                    for try await chunk in reader {
                        XCTAssertEqual(chunk, testChunk)
                        receiveExpectation.fulfill()
                    }
                } catch {
                    XCTFail("Read failed: \(error.localizedDescription)")
                }
            }

            do {
                let writer = try await room1.localParticipant.streamText(for: topic)
                try await writer.write(testChunk)
                try await writer.close()
            } catch {
                XCTFail("Write failed: \(error.localizedDescription)")
            }

            await self.fulfillment(
                of: [receiveExpectation],
                timeout: 5
            )
        }
    }
    
    func testStreamBytes() async throws {
        let receiveExpectation = expectation(description: "Receives stream chunk")
        let topic = "some-topic"
        let testChunk = Data(repeating: 0xFF, count: 256)

        try await withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let room0 = rooms[0]
            let room1 = rooms[1]

            try await room0.registerByteStreamHandler(for: topic) { reader, participant in
                XCTAssertEqual(participant, room1.localParticipant.identity)
                do {
                    for try await chunk in reader {
                        XCTAssertEqual(chunk, testChunk)
                        receiveExpectation.fulfill()
                    }
                } catch {
                    XCTFail("Read failed: \(error.localizedDescription)")
                }
            }

            do {
                let writer = try await room1.localParticipant.streamBytes(for: topic)
                try await writer.write(testChunk)
                try await writer.close()
            } catch {
                XCTFail("Write failed: \(error.localizedDescription)")
            }

            await self.fulfillment(
                of: [receiveExpectation],
                timeout: 5
            )
        }
    }
}
