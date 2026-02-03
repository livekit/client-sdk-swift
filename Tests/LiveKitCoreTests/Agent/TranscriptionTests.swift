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
import OrderedCollections
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

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
    private var rooms: [Room] = []
    private var receiver: TranscriptionStreamReceiver!
    private var senderRoom: Room!
    private var messageCollector: MessageCollector!
    private var collectionTask: AnyTaskCancellable!
    private var messageExpectation: XCTestExpectation!

    // Same segment, same stream
    func testUpdates() async throws {
        let segmentID = "test-segment"
        let streamID = UUID().uuidString
        let testChunks = ["Hey", " there!", " What's up?"]
        let expectedContent = ["Hey", "Hey there!", "Hey there! What's up?"]

        try await runTranscriptionTest(
            chunks: testChunks,
            segmentID: segmentID,
            streamID: streamID,
            expectedContent: expectedContent
        )
    }

    // Same segment, different stream
    func testReplace() async throws {
        let segmentID = "test-segment"
        let testChunks = ["Hey", "Hey there!", "Hey there! What's up?"]
        let expectedContent = ["Hey", "Hey there!", "Hey there! What's up?"]

        try await runTranscriptionTest(
            chunks: testChunks,
            segmentID: segmentID,
            streamID: nil,
            expectedContent: expectedContent
        )
    }

    private func setupTestEnvironment(expectedCount: Int) async throws {
        messageExpectation = expectation(description: "Receives all message updates")
        messageExpectation.expectedFulfillmentCount = expectedCount

        receiver = TranscriptionStreamReceiver(room: rooms[0])
        let messageStream = try await receiver.messages()
        messageCollector = MessageCollector()
        senderRoom = rooms[1]

        collectionTask = messageStream.subscribe(self) { observer, message in
            await observer.messageCollector.add(message)
            observer.messageExpectation.fulfill()
        }
    }

    private func sendTranscriptionChunks(
        chunks: [String],
        segmentID: String,
        streamID: String? = nil,
        to room: Room
    ) async throws {
        let topic = "lk.transcription"

        for (index, chunk) in chunks.enumerated() {
            let isLast = index == chunks.count - 1

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
                id: streamID ?? UUID().uuidString
            )

            try await room.localParticipant.sendText(chunk, options: options)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func validateTranscriptionResults(
        updates: [ReceivedMessage],
        messages: OrderedDictionary<ReceivedMessage.ID, ReceivedMessage>,
        segmentID: String,
        expectedContent: [String]
    ) {
        // Validate updates
        XCTAssertEqual(updates.count, expectedContent.count)
        for (index, expected) in expectedContent.enumerated() {
            XCTAssertEqual(updates[index].content, .agentTranscript(expected))
            XCTAssertEqual(updates[index].id, segmentID)
        }

        // Validate timestamps are consistent
        let firstTimestamp = updates[0].timestamp
        for update in updates {
            XCTAssertEqual(update.timestamp, firstTimestamp)
        }

        // Validate final message
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.keys[0], segmentID)
        XCTAssertEqual(messages.values[0].content, .agentTranscript(expectedContent.last!))
        XCTAssertEqual(messages.values[0].id, segmentID)
        XCTAssertEqual(messages.values[0].timestamp, firstTimestamp)
    }

    private func runTranscriptionTest(
        chunks: [String],
        segmentID: String,
        streamID: String? = nil,
        expectedContent: [String]
    ) async throws {
        try await withRooms([
            RoomTestingOptions(canSubscribe: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            self.rooms = rooms
            try await self.setupTestEnvironment(expectedCount: expectedContent.count)
            try await self.sendTranscriptionChunks(
                chunks: chunks,
                segmentID: segmentID,
                streamID: streamID,
                to: self.senderRoom
            )

            await self.fulfillment(of: [self.messageExpectation], timeout: 5)
            self.collectionTask.cancel()

            let updates = await self.messageCollector.getUpdates()
            let messages = await self.messageCollector.getMessages()

            self.validateTranscriptionResults(
                updates: updates,
                messages: messages,
                segmentID: segmentID,
                expectedContent: expectedContent
            )
        }
    }
}
