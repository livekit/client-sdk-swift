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

import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class DataStreamTests: LKTestCase {
    private enum Method {
        case send, stream
    }

    func testStreamText() async throws {
        try await _textDataStream(method: .stream)
    }

    func testSendText() async throws {
        try await _textDataStream(method: .send)
    }

    func testStreamBytes() async throws {
        try await _byteDataStream(method: .stream)
    }

    func testSendFile() async throws {
        try await _byteDataStream(method: .send)
    }

    private func _textDataStream(method: Method) async throws {
        let receiveExpectation = expectation(description: "Receives stream chunk")
        let topic = "some-topic"
        let testChunk = "Hello world!"

        try await withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let room0 = rooms[0]
            let room1 = rooms[1]

            try await room0.registerTextStreamHandler(for: topic) { reader, participant in
                XCTAssertEqual(participant, room1.localParticipant.identity)
                do {
                    let chunk = try await reader.readAll()
                    XCTAssertEqual(chunk, testChunk)
                    receiveExpectation.fulfill()
                } catch {
                    XCTFail("Read failed: \(error.localizedDescription)")
                }
            }

            do {
                switch method {
                case .send:
                    try await room1.localParticipant.sendText(testChunk, for: topic)
                case .stream:
                    let writer = try await room1.localParticipant.streamText(for: topic)
                    try await writer.write(testChunk)
                    try await writer.close()
                }
            } catch {
                XCTFail("Write failed: \(error.localizedDescription)")
            }

            await self.fulfillment(
                of: [receiveExpectation],
                timeout: 5
            )
        }
    }

    private func _byteDataStream(method: Method) async throws {
        let receiveExpectation = expectation(description: "Receives stream chunk")
        let topic = "some-topic"
        let testChunk = Data(repeating: 0xFF, count: 256)

        try await withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let room0 = rooms[0]
            let room1 = rooms[1]

            try await room0.registerByteStreamHandler(for: topic) { reader, participant in
                XCTAssertEqual(participant, room1.localParticipant.identity)
                do {
                    let chunk = try await reader.readAll()
                    XCTAssertEqual(chunk, testChunk)
                    receiveExpectation.fulfill()
                } catch {
                    XCTFail("Read failed: \(error.localizedDescription)")
                }
            }

            do {
                switch method {
                case .send:
                    // Only sending files is supported, write chunk to file first
                    let fileURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("file-name.pdf")
                    try testChunk.write(to: fileURL)

                    let info = try await room1.localParticipant.sendFile(fileURL, for: topic)

                    XCTAssertEqual(info.name, fileURL.lastPathComponent)
                    XCTAssertEqual(info.mimeType, "application/pdf")
                    XCTAssertEqual(info.totalLength, testChunk.count)

                case .stream:
                    let writer = try await room1.localParticipant.streamBytes(for: topic)
                    try await writer.write(testChunk)
                    try await writer.close()
                }
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
