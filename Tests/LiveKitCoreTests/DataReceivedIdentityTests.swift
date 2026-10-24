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

private struct ReceivedData {
    var identity: String?
    var hadParticipant = false
    var received = false
}

private final class DataRecorder: NSObject, RoomDelegate, @unchecked Sendable {
    private let _state = StateSync(ReceivedData())

    // swiftlint:disable:next function_parameter_count
    func room(_: Room,
              participant: RemoteParticipant?,
              participantIdentity: Participant.Identity,
              didReceiveData _: Data,
              forTopic _: String,
              encryptionType _: EncryptionType)
    {
        _state.mutate {
            $0 = ReceivedData(identity: participantIdentity.stringValue,
                              hadParticipant: participant != nil,
                              received: true)
        }
    }

    var snapshot: ReceivedData { _state.copy() }
}

/// `participant` is nil whenever the sender is not in the room, so without the identity the
/// receiver cannot tell who sent the data at all.
struct DataReceivedIdentityTests {
    private func waitForDelivery(_ recorder: DataRecorder) async throws {
        for _ in 0 ..< 100 {
            if recorder.snapshot.received { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("the delegate was never notified")
    }

    private func deliver(userPacket: Livekit_UserPacket,
                         outerIdentity: String) async throws -> ReceivedData
    {
        let room = Room()
        room._state.mutate { $0.connectionState = .connected }

        let recorder = DataRecorder()
        room.delegates.add(delegate: recorder)

        await room.engine(room,
                          didReceiveUserPacket: userPacket,
                          participantIdentity: outerIdentity,
                          encryptionType: .none)
        try await waitForDelivery(recorder)
        return recorder.snapshot
    }

    /// Newer servers set the identity only on the enclosing `DataPacket`, leaving `UserPacket`'s
    /// deprecated copy empty, so the outer value has to win.
    @Test func reportsSenderIdentityWhenTheParticipantIsNotInTheRoom() async throws {
        let packet = Livekit_UserPacket.with {
            $0.payload = Data("hello".utf8)
            $0.topic = "greetings"
        }

        let result = try await deliver(userPacket: packet, outerIdentity: "server-api-sender")

        #expect(result.hadParticipant == false, "the sender is not a participant in this room")
        #expect(result.identity == "server-api-sender")
    }

    /// Older servers set only the deprecated `UserPacket` copy, which must still be honoured.
    @Test func fallsBackToTheDeprecatedPacketIdentity() async throws {
        let packet = Livekit_UserPacket.with {
            $0.participantIdentity = "legacy-sender"
            $0.payload = Data("hello".utf8)
            $0.topic = "greetings"
        }

        let result = try await deliver(userPacket: packet, outerIdentity: "")

        #expect(result.identity == "legacy-sender")
    }
}
