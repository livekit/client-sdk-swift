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
    private let lock = NSLock()
    private var _state = ReceivedData()

    // swiftlint:disable:next function_parameter_count
    func room(_: Room,
              participant: RemoteParticipant?,
              participantIdentity: Participant.Identity,
              didReceiveData _: Data,
              forTopic _: String,
              encryptionType _: EncryptionType)
    {
        lock.lock()
        defer { lock.unlock() }
        _state = ReceivedData(identity: participantIdentity.stringValue,
                              hadParticipant: participant != nil,
                              received: true)
    }

    var snapshot: ReceivedData {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }
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

    @Test func reportsSenderIdentityWhenTheParticipantIsNotInTheRoom() async throws {
        let room = Room()
        room._state.mutate { $0.connectionState = .connected }

        let recorder = DataRecorder()
        room.delegates.add(delegate: recorder)

        let packet = Livekit_UserPacket.with {
            $0.participantIdentity = "server-api-sender"
            $0.payload = Data("hello".utf8)
            $0.topic = "greetings"
        }

        await room.engine(room, didReceiveUserPacket: packet, encryptionType: .none)
        try await waitForDelivery(recorder)

        let result = recorder.snapshot
        #expect(result.hadParticipant == false, "the sender is not a participant in this room")
        #expect(result.identity == "server-api-sender")
    }
}
