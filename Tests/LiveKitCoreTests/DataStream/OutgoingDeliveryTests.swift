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
import LiveKitFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// The outgoing delegate is `async`, so a transport failure propagates back to the call that caused
/// it. While it returned `Void` neither of these held: a failed send was swallowed, `write` resolved
/// as if it had succeeded, and `isOpen` stayed `true` on a stream that could no longer be written.
@Suite(.serialized, .tags(.dataStream, .e2e))
struct OutgoingDeliveryTests {
    @Test func writeFailsAndClosesStreamWhenTransportIsGone() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let sender = rooms[1]
            let writer = try await sender.localParticipant.streamBytes(options: LiveKit.StreamByteOptions(topic: "delivery"))

            try await writer.write(Data(repeating: 0x01, count: 1024))
            // Read out of the macro: under Swift 6.1 `#expect` puts its expression somewhere an
            // `async` property access can't go.
            var isOpen = await writer.isOpen
            #expect(isOpen)

            await sender.disconnect()

            // The disconnect released the manager that served the stream, so the core reports
            // its closed request channel rather than a failed send.
            await #expect(throws: StreamError.internalError) {
                try await writer.write(Data(repeating: 0x02, count: 1024))
            }
            isOpen = await writer.isOpen
            #expect(!isOpen)
        }
    }

    /// The remote side loses every open stream in a full reconnect, so a writer opened before it
    /// must fail rather than send its next chunk into a session where no receiver saw the header.
    @Test func writeFailsAfterFullReconnect() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let sender = rooms[1]
            let writer = try await sender.localParticipant.streamText(for: "delivery")
            try await writer.write("before")

            try await sender.debug_simulate(scenario: .fullReconnect)
            #expect(sender.connectionState == .connected)

            await #expect(throws: StreamError.self) {
                try await writer.write("after")
            }
            let isOpen = await writer.isOpen
            #expect(!isOpen)
        }
    }

    /// A send that still holds the manager a full reconnect replaced, such as one in flight during
    /// the reconnect, keeps that manager's packet pump running. What it emits must not reach the
    /// new session, so the replaced manager's delegate has to fail it.
    @Test func replacedManagerCannotSendIntoNewSession() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let sender = rooms[1]
            let replaced = try #require(sender._state.stage.connection?.outgoingDataStreams.copy().manager)
            let writer = try await replaced.streamText(options: LiveKitFFI.StreamTextOptions(topic: "delivery", attributes: [:]))
            try await writer.write(text: "before")

            try await sender.debug_simulate(scenario: .fullReconnect)
            #expect(sender.connectionState == .connected)

            // A writer opened before the swap.
            await #expect(throws: LiveKitFFI.DataStreamError.self) {
                try await writer.write(text: "after")
            }
            // A stream opened on the replaced manager after the swap, as one whose creation
            // overlapped it would be.
            await #expect(throws: LiveKitFFI.DataStreamError.self) {
                _ = try await replaced.streamText(options: LiveKitFFI.StreamTextOptions(topic: "delivery", attributes: [:]))
            }
        }
    }

    /// The room stamps every outgoing packet with the local identity, except a data stream packet
    /// that already names the identity it is sent on behalf of. The local dev server then replaces
    /// that identity with the sender's own, so this is checked where the packet leaves the room.
    @Test func streamSentOnBehalfKeepsItsIdentity() async throws {
        try await TestEnvironment.withRoom { room in
            let sent = StateSync<[Livekit_DataPacket]>([])
            room.publisherDataChannel = MockDataChannelPair { packet in sent.mutate { $0.append(packet) } }
            let local = try #require(room.localParticipant.identity?.stringValue)

            _ = try await room.localParticipant.sendText("hi", options: StreamTextOptions(topic: "topic", senderIdentity: Participant.Identity(from: "on-behalf")))
            #expect(!sent.copy().isEmpty)
            #expect(sent.copy().allSatisfy { $0.participantIdentity == "on-behalf" })

            sent.mutate { $0 = [] }
            _ = try await room.localParticipant.sendText("hi", for: "topic")
            #expect(!sent.copy().isEmpty)
            #expect(sent.copy().allSatisfy { $0.participantIdentity == local })

            sent.mutate { $0 = [] }
            try await room.send(dataPacket: Livekit_DataPacket.with {
                $0.participantIdentity = "on-behalf"
                $0.user = Livekit_UserPacket.with { $0.payload = Data([1]) }
            })
            #expect(sent.copy().map(\.participantIdentity) == [local])
        }
    }
}
