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

/// An actor that converts raw text streams from the LiveKit `Room` into `Message` objects.
/// - Note: Streams are supported by `livekit-agents` >= 1.0.0.
/// - SeeAlso: ``TranscriptionDelegateReceiver``
///
/// For agent messages, new text stream is emitted for each message, and the stream is closed when the message is finalized.
/// Each agent message is delivered in chunks, that are accumulated and published into the message stream.
///
/// For user messages, the full transcription is sent each time, but may be updated until finalized.
///
/// The ID of the segment is stable and unique across the lifetime of the message.
/// This ID can be used directly for `Identifiable` conformance.
///
/// Example text stream for agent messages:
/// ```
/// { segment_id: "1", content: "Hello" }
/// { segment_id: "1", content: " world" }
/// { segment_id: "1", content: "!" }
/// { segment_id: "2", content: "Hello" }
/// { segment_id: "2", content: " Apple" }
/// { segment_id: "2", content: "!" }
/// ```
///
/// Example text stream for user messages:
/// ```
/// { segment_id: "3", content: "Hello" }
/// { segment_id: "3", content: "Hello world!" }
/// { segment_id: "4", content: "Hello" }
/// { segment_id: "4", content: "Hello Apple!" }
/// ```
///
/// Example output:
/// ```
/// Message(id: "1", timestamp: 2025-01-01 12:00:00 +0000, content: .agentTranscript("Hello world!"))
/// Message(id: "2", timestamp: 2025-01-01 12:00:10 +0000, content: .agentTranscript("Hello Apple!"))
/// Message(id: "3", timestamp: 2025-01-01 12:00:20 +0000, content: .userTranscript("Hello world!"))
/// Message(id: "4", timestamp: 2025-01-01 12:00:30 +0000, content: .userTranscript("Hello Apple!"))
/// ```
///
actor TranscriptionStreamReceiver: MessageReceiver, Loggable {
    private struct PartialMessageID: Hashable {
        let segmentID: String
        let participantID: Participant.Identity
    }

    private struct PartialMessage {
        var content: String
        let timestamp: Date
        var streamID: String

        mutating func appendContent(_ newContent: String) {
            content += newContent
        }

        mutating func replaceContent(_ newContent: String, streamID: String) {
            content = newContent
            self.streamID = streamID
        }
    }

    private let room: Room
    private let topic: String

    private lazy var partialMessages: [PartialMessageID: PartialMessage] = [:]

    init(room: Room, topic: String = "lk.transcription") {
        self.room = room
        self.topic = topic
    }

    /// Creates a new message stream for the chat topic.
    func messages() async throws -> AsyncStream<ReceivedMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: ReceivedMessage.self)

        let topic = topic

        try await room.registerTextStreamHandler(for: topic) { [weak self] reader, participantIdentity in
            for try await message in reader where !message.isEmpty {
                guard let self else { return }
                await continuation.yield(processIncoming(partialMessage: message, reader: reader, participantIdentity: participantIdentity))
            }
        }

        continuation.onTermination = { _ in
            Task { [weak self] in
                await self?.room.unregisterTextStreamHandler(for: topic)
            }
        }

        return stream
    }

    /// Aggregates the incoming text into a message, storing the partial content in the `partialMessages` dictionary.
    /// - Note: When the message is finalized, or a new message is started, the dictionary is purged to limit memory usage.
    private func processIncoming(partialMessage message: String, reader: TextStreamReader, participantIdentity: Participant.Identity) -> ReceivedMessage {
        let attributes = reader.info.attributes.mapped(to: TranscriptionAttributes.self)
        if attributes == nil {
            log("Unable to read message attributes from \(reader.info.attributes)", .error)
        }

        let segmentID = attributes?.lkSegmentID ?? reader.info.id
        let participantID = participantIdentity
        let partialID = PartialMessageID(segmentID: segmentID, participantID: participantID)

        let currentStreamID = reader.info.id

        let timestamp: Date
        let updatedContent: String

        if var existingMessage = partialMessages[partialID] {
            // Update existing message
            if existingMessage.streamID == currentStreamID {
                // Same stream, append content
                existingMessage.appendContent(message)
            } else {
                // Different stream for same segment, replace content
                existingMessage.replaceContent(message, streamID: currentStreamID)
            }
            updatedContent = existingMessage.content
            timestamp = existingMessage.timestamp
            partialMessages[partialID] = existingMessage
        } else {
            // This is a new message
            updatedContent = message
            timestamp = reader.info.timestamp
            partialMessages[partialID] = PartialMessage(
                content: updatedContent,
                timestamp: timestamp,
                streamID: currentStreamID
            )
            cleanupPreviousTurn(participantIdentity, exceptSegmentID: segmentID)
        }

        let isFinal = attributes?.lkTranscriptionFinal ?? false
        if isFinal {
            partialMessages[partialID] = nil
        }

        return ReceivedMessage(
            id: segmentID,
            timestamp: timestamp,
            content: participantIdentity == room.localParticipant.identity ? .userTranscript(updatedContent) : .agentTranscript(updatedContent)
        )
    }

    private func cleanupPreviousTurn(_ participantID: Participant.Identity, exceptSegmentID: String) {
        let keysToRemove = partialMessages.keys.filter {
            $0.participantID == participantID && $0.segmentID != exceptSegmentID
        }

        for key in keysToRemove {
            partialMessages[key] = nil
        }
    }
}
