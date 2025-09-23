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
import OrderedCollections
import XCTest

actor MessageCollector {
    private var updates: [ReceivedMessage] = []
    private var messages: OrderedDictionary<ReceivedMessage.ID, ReceivedMessage> = [:]

    func add(_ message: ReceivedMessage) {
        updates.append(message)
        messages[message.id] = message
    }

    func getUpdates() -> [ReceivedMessage] {
        updates
    }

    func getMessages() -> OrderedDictionary<ReceivedMessage.ID, ReceivedMessage> {
        messages
    }
}

class TranscriptionTests: LKTestCase, @unchecked Sendable {
    // Same segment, same stream
    func testUpdates() async throws {
        let messageExpectation = expectation(description: "Receives all message updates")
        messageExpectation.expectedFulfillmentCount = 3

        let segmentID = "test-segment"
        let topic = "lk.transcription"

        let testChunks = ["Hey", " there!", " What's up?"]

        try await withRooms([
            RoomTestingOptions(canSubscribe: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let receiverRoom = rooms[0]
            let senderRoom = rooms[1]

            let receiver = TranscriptionStreamReceiver(room: receiverRoom)
            let messageStream = try await receiver.messages()
            let streamID = UUID().uuidString

            let messageCollector = MessageCollector()

            let collectionTask = Task { @Sendable in
                var iterator = messageStream.makeAsyncIterator()
                while let message = await iterator.next() {
                    await messageCollector.add(message)
                    messageExpectation.fulfill()
                }
            }

            for (index, chunk) in testChunks.enumerated() {
                let isLast = index == testChunks.count - 1

                var attributes: [String: String] = [
                    "lk.segment_id": segmentID,
                    "lk.transcription_final": "false",
                ]

                if isLast {
                    attributes["lk.transcription_final"] = "true"
                }

                let options = StreamTextOptions(
                    topic: topic,
                    attributes: attributes,
                    id: streamID
                )

                try await senderRoom.localParticipant.sendText(chunk, options: options)
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            await self.fulfillment(of: [messageExpectation], timeout: 5)
            collectionTask.cancel()

            let updates = await messageCollector.getUpdates()
            XCTAssertEqual(updates.count, 3)
            XCTAssertEqual(updates[0].content, .agentTranscript("Hey"))
            XCTAssertEqual(updates[1].content, .agentTranscript("Hey there!"))
            XCTAssertEqual(updates[2].content, .agentTranscript("Hey there! What's up?"))

            XCTAssertEqual(updates[0].id, segmentID)
            XCTAssertEqual(updates[1].id, segmentID)
            XCTAssertEqual(updates[2].id, segmentID)

            let firstTimestamp = updates[0].timestamp
            XCTAssertEqual(updates[1].timestamp, firstTimestamp)
            XCTAssertEqual(updates[2].timestamp, firstTimestamp)

            let messages = await messageCollector.getMessages()
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages.keys[0], segmentID)
            XCTAssertEqual(messages.values[0].content, .agentTranscript("Hey there! What's up?"))
            XCTAssertEqual(messages.values[0].id, segmentID)
            XCTAssertEqual(messages.values[0].timestamp, firstTimestamp)
        }
    }

    // Same segment, different stream
    func testReplace() async throws {
        let messageExpectation = expectation(description: "Receives all message updates")
        messageExpectation.expectedFulfillmentCount = 3

        let segmentID = "test-segment"
        let topic = "lk.transcription"

        let testChunks = ["Hey", "Hey there!", "Hey there! What's up?"]

        try await withRooms([
            RoomTestingOptions(canSubscribe: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let receiverRoom = rooms[0]
            let senderRoom = rooms[1]

            let receiver = TranscriptionStreamReceiver(room: receiverRoom)
            let messageStream = try await receiver.messages()

            let messageCollector = MessageCollector()

            let collectionTask = Task { @Sendable in
                var iterator = messageStream.makeAsyncIterator()
                while let message = await iterator.next() {
                    await messageCollector.add(message)
                    messageExpectation.fulfill()
                }
            }

            for (index, chunk) in testChunks.enumerated() {
                let isLast = index == testChunks.count - 1

                var attributes: [String: String] = [
                    "lk.segment_id": segmentID,
                    "lk.transcription_final": "false",
                ]

                if isLast {
                    attributes["lk.transcription_final"] = "true"
                }

                let options = StreamTextOptions(
                    topic: topic,
                    attributes: attributes,
                    id: UUID().uuidString
                )

                try await senderRoom.localParticipant.sendText(chunk, options: options)
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            await self.fulfillment(of: [messageExpectation], timeout: 5)
            collectionTask.cancel()

            let updates = await messageCollector.getUpdates()
            XCTAssertEqual(updates.count, 3)
            XCTAssertEqual(updates[0].content, .agentTranscript("Hey"))
            XCTAssertEqual(updates[1].content, .agentTranscript("Hey there!"))
            XCTAssertEqual(updates[2].content, .agentTranscript("Hey there! What's up?"))

            XCTAssertEqual(updates[0].id, segmentID)
            XCTAssertEqual(updates[1].id, segmentID)
            XCTAssertEqual(updates[2].id, segmentID)

            let firstTimestamp = updates[0].timestamp
            XCTAssertEqual(updates[1].timestamp, firstTimestamp)
            XCTAssertEqual(updates[2].timestamp, firstTimestamp)

            let messages = await messageCollector.getMessages()
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages.keys[0], segmentID)
            XCTAssertEqual(messages.values[0].content, .agentTranscript("Hey there! What's up?"))
            XCTAssertEqual(messages.values[0].id, segmentID)
            XCTAssertEqual(messages.values[0].timestamp, firstTimestamp)
        }
    }
}
