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

import Foundation
@testable import LiveKit
import Testing
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

@Suite(.serialized, .tags(.e2e)) final class TranscriptionTests: @unchecked Sendable {
    // Same segment, same stream
    @Test func updates() async throws {
        let segmentID = "test-segment"
        let streamID = UUID().uuidString
        let testChunks = ["Hey", " there!", " What's up?"]
        // Each sendText creates a separate stream. Non-final streams emit a
        // stream-close finalization message after their content message.
        let expectedContent = ["Hey", "Hey", "Hey there!", "Hey there!", "Hey there! What's up?"]
        let expectedIsFinal = [false, true, false, true, true]

        try await runTranscriptionTest(
            chunks: testChunks,
            segmentID: segmentID,
            streamID: streamID,
            expectedContent: expectedContent,
            expectedIsFinal: expectedIsFinal
        )
    }

    // Same segment, different stream
    @Test func replace() async throws {
        let segmentID = "test-segment"
        let testChunks = ["Hey", "Hey there!", "Hey there! What's up?"]
        let expectedContent = ["Hey", "Hey", "Hey there!", "Hey there!", "Hey there! What's up?"]
        let expectedIsFinal = [false, true, false, true, true]

        try await runTranscriptionTest(
            chunks: testChunks,
            segmentID: segmentID,
            streamID: nil,
            expectedContent: expectedContent,
            expectedIsFinal: expectedIsFinal
        )
    }

    // Verifies stream-close finalization for a single stream with incremental writes.
    // This mirrors real agent behavior where all chunks arrive within one stream
    // and the attribute is always "false" — finality comes from the stream closing.
    @Test func streamCloseFinalizes() async throws {
        let segmentID = "test-segment"
        let testChunks = ["Hey", " there!", " What's up?"]
        let expectedContent = ["Hey", "Hey there!", "Hey there! What's up?", "Hey there! What's up?"]
        let expectedIsFinal = [false, false, false, true]

        try await TestEnvironment.withRooms([
            RoomTestingOptions(canSubscribe: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            self.rooms = rooms
            try await self.setupTestEnvironment(rooms: rooms)

            try await confirmation("Receives all message updates", expectedCount: expectedContent.count) { confirm in
                self.collectionTask.cancel()
                let messageStream = try await self.receiver.messages()
                self.collectionTask = messageStream.subscribe(self) { observer, message in
                    await observer.messageCollector.add(message)
                    confirm()
                }

                let topic = "lk.transcription"
                let attributes: [String: String] = [
                    "lk.segment_id": segmentID,
                    "lk.transcription_final": "false",
                ]
                let options = StreamTextOptions(topic: topic, attributes: attributes)
                let writer = try await self.senderRoom.localParticipant.streamText(options: options)
                for chunk in testChunks {
                    try await writer.write(chunk)
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try await writer.close()
            }

            self.collectionTask.cancel()

            let updates = await self.messageCollector.getUpdates()
            let messages = await self.messageCollector.getMessages()

            self.validateTranscriptionResults(
                updates: updates,
                messages: messages,
                segmentID: segmentID,
                expectedContent: expectedContent,
                expectedIsFinal: expectedIsFinal
            )
        }
    }

    // Verifies that no duplicate finalization message is emitted when
    // the attribute already marks the segment as final.
    @Test func attributeBasedIsFinal() async throws {
        let segmentID = "test-segment"
        let expectedContent = ["Hello!"]
        let expectedIsFinal = [true]

        try await TestEnvironment.withRooms([
            RoomTestingOptions(canSubscribe: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            self.rooms = rooms
            try await self.setupTestEnvironment(rooms: rooms)

            try await confirmation("Receives single message", expectedCount: 1) { confirm in
                self.collectionTask.cancel()
                let messageStream = try await self.receiver.messages()
                self.collectionTask = messageStream.subscribe(self) { observer, message in
                    await observer.messageCollector.add(message)
                    confirm()
                }

                let topic = "lk.transcription"
                let attributes: [String: String] = [
                    "lk.segment_id": segmentID,
                    "lk.transcription_final": "true",
                ]
                let options = StreamTextOptions(topic: topic, attributes: attributes)
                try await self.senderRoom.localParticipant.sendText("Hello!", options: options)
            }

            // Brief wait to ensure no extra messages arrive
            try await Task.sleep(nanoseconds: 100_000_000)
            self.collectionTask.cancel()

            let updates = await self.messageCollector.getUpdates()
            let messages = await self.messageCollector.getMessages()

            // Exactly 1 message — no duplicate from stream-close
            self.validateTranscriptionResults(
                updates: updates,
                messages: messages,
                segmentID: segmentID,
                expectedContent: expectedContent,
                expectedIsFinal: expectedIsFinal
            )
        }
    }

    private func setupTestEnvironment(rooms: [Room]) async throws {
        receiver = TranscriptionStreamReceiver(room: rooms[0])
        let messageStream = try await receiver.messages()
        messageCollector = MessageCollector()
        senderRoom = rooms[1]

        collectionTask = messageStream.subscribe(self) { observer, message in
            await observer.messageCollector.add(message)
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
        expectedContent: [String],
        expectedIsFinal: [Bool]
    ) {
        // Validate updates
        #expect(updates.count == expectedContent.count)
        for (index, expected) in expectedContent.enumerated() {
            #expect(updates[index].content == .agentTranscript(expected))
            #expect(updates[index].id == segmentID)
        }

        // Validate isFinal
        #expect(updates.count == expectedIsFinal.count)
        for (index, expected) in expectedIsFinal.enumerated() {
            #expect(updates[index].isFinal == expected, "isFinal mismatch at index \(index)")
        }

        // Validate timestamps are consistent
        let firstTimestamp = updates[0].timestamp
        for update in updates {
            #expect(update.timestamp == firstTimestamp)
        }

        // Validate final message
        #expect(messages.count == 1)
        #expect(messages.keys[0] == segmentID)
        #expect(messages.values[0].content == .agentTranscript(expectedContent.last!))
        #expect(messages.values[0].id == segmentID)
        #expect(messages.values[0].timestamp == firstTimestamp)
        #expect(messages.values[0].isFinal)
    }

    private func runTranscriptionTest(
        chunks: [String],
        segmentID: String,
        streamID: String? = nil,
        expectedContent: [String],
        expectedIsFinal: [Bool]
    ) async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canSubscribe: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let receiver = TranscriptionStreamReceiver(room: rooms[0])
            let messageStream = try await receiver.messages()
            let messageCollector = MessageCollector()
            let senderRoom = rooms[1]

            try await confirmation("Receives all message updates", expectedCount: expectedContent.count) { confirm in
                let collectionTask = messageStream.subscribe(self) { _, message in
                    await messageCollector.add(message)
                    confirm()
                }

                defer { collectionTask.cancel() }

                try await self.sendTranscriptionChunks(
                    chunks: chunks,
                    segmentID: segmentID,
                    streamID: streamID,
                    to: senderRoom
                )
            }

            let updates = await messageCollector.getUpdates()
            let messages = await messageCollector.getMessages()

            self.validateTranscriptionResults(
                updates: updates,
                messages: messages,
                segmentID: segmentID,
                expectedContent: expectedContent,
                expectedIsFinal: expectedIsFinal
            )
        }
    }
}
