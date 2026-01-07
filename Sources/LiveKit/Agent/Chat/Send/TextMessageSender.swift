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

/// An actor that sends local messages to the agent.
/// Currently, it only supports sending text messages.
///
/// It also serves as the loopback for the local messages,
/// so that they can be displayed in the message feed
/// without relying on the agent-side transcription.
actor TextMessageSender: MessageSender, MessageReceiver {
    private let room: Room
    private let topic: String

    private var messageContinuation: AsyncStream<ReceivedMessage>.Continuation?

    init(room: Room, topic: String = "lk.chat") {
        self.room = room
        self.topic = topic
    }

    deinit {
        messageContinuation?.finish()
    }

    func send(_ message: SentMessage) async throws {
        guard case let .userInput(text) = message.content else { return }

        try await room.localParticipant.sendText(text, for: topic)

        let loopbackMessage = ReceivedMessage(
            id: message.id,
            timestamp: message.timestamp,
            content: .userInput(text)
        )

        messageContinuation?.yield(loopbackMessage)
    }

    func messages() async throws -> AsyncStream<ReceivedMessage> {
        let (stream, continuation) = AsyncStream<ReceivedMessage>.makeStream()
        messageContinuation = continuation
        return stream
    }
}
