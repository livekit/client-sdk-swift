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

/// What one delivery reported, across both the new and the legacy callback.
private struct ReceivedData {
    let identity: String?
    let hadParticipant: Bool
    /// Whether ``RoomDelegate/room(_:participant:didReceiveData:forTopic:encryptionType:)`` also
    /// fired, and the participant it reported. Both callbacks fire for every packet.
    let legacyFired: Bool
    let legacyHadParticipant: Bool
}

/// Records both data callbacks and resolves once the identity-carrying one fires.
///
/// The legacy callback is notified first in the same `delegates.notify` block, so a resolved
/// value always carries its outcome too.
private final class DataRecorder: NSObject, RoomDelegate, @unchecked Sendable {
    private let _legacy = StateSync<Bool?>(nil)
    private let _completer = AsyncCompleter<ReceivedData>(label: "Data received", defaultTimeout: 10)

    func room(_: Room,
              participant: RemoteParticipant?,
              didReceiveData _: Data,
              forTopic _: String,
              encryptionType _: EncryptionType)
    {
        _legacy.mutate { $0 = participant != nil }
    }

    // swiftlint:disable:next function_parameter_count
    func room(_: Room,
              participant: RemoteParticipant?,
              participantIdentity: Participant.Identity?,
              didReceiveData _: Data,
              forTopic _: String,
              encryptionType _: EncryptionType)
    {
        let legacy = _legacy.copy()
        _completer.resume(returning: ReceivedData(identity: participantIdentity?.stringValue,
                                                  hadParticipant: participant != nil,
                                                  legacyFired: legacy != nil,
                                                  legacyHadParticipant: legacy ?? false))
    }

    /// Waits for the delivery, throwing if it never arrives — so an assertion can never pass
    /// against a value that was simply never set.
    func wait() async throws -> ReceivedData {
        try await _completer.wait()
    }
}

@Suite(.tags(.dataChannel), .spec("https://github.com/livekit/client-sdk-js/pull/2092"))
struct DataReceivedIdentityTests {
    /// Which of the two identity fields the server populated.
    struct IdentityCase: CustomTestStringConvertible {
        let outer: String
        let legacy: String
        let expected: String?
        let description: String
        var testDescription: String { description }
    }

    /// The enclosing `DataPacket` wins where both are set; the deprecated `UserPacket` copy is the
    /// fallback for servers older than the sync that keeps the two equal; neither set means the
    /// server named no sender, which is reported as nil rather than an empty identity.
    @Test(arguments: [
        IdentityCase(outer: "outer-sender", legacy: "", expected: "outer-sender",
                     description: "outer only"),
        IdentityCase(outer: "", legacy: "legacy-sender", expected: "legacy-sender",
                     description: "deprecated copy only"),
        IdentityCase(outer: "outer-sender", legacy: "legacy-sender", expected: "outer-sender",
                     description: "both set, outer wins"),
        IdentityCase(outer: "", legacy: "", expected: nil,
                     description: "neither set, no sender"),
    ])
    func reportsTheSenderIdentity(_ testCase: IdentityCase) async throws {
        let result = try await Self.deliver(outerIdentity: testCase.outer,
                                            legacyIdentity: testCase.legacy)

        #expect(result.identity == testCase.expected)
        #expect(result.hadParticipant == false, "the sender is not a participant in this room")
        #expect(result.legacyFired, "the existing callback must still fire for every packet")
    }

    /// With the sender in the room both callbacks resolve the participant, and the identity still
    /// accompanies it.
    @Test func reportsBothParticipantAndIdentityForAnInRoomSender() async throws {
        let identity = "in-room-sender"
        let result = try await Self.deliver(outerIdentity: identity,
                                            legacyIdentity: "",
                                            remoteParticipant: identity)

        #expect(result.identity == identity)
        #expect(result.hadParticipant, "the sender is a participant in this room")
        #expect(result.legacyHadParticipant, "the existing callback resolves the same participant")
    }

    /// Feeds one user packet through the receive path and returns what the delegates saw.
    private static func deliver(outerIdentity: String,
                                legacyIdentity: String,
                                remoteParticipant: String? = nil) async throws -> ReceivedData
    {
        let room = Room()
        room._state.mutate { $0.connectionState = .connected }

        if let remoteParticipant {
            let info = Livekit_ParticipantInfo.with {
                $0.sid = "PA_\(remoteParticipant)"
                $0.identity = remoteParticipant
            }
            let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)
            room._state.mutate {
                $0.remoteParticipants[Participant.Identity(from: remoteParticipant)] = participant
            }
        }

        let recorder = DataRecorder()
        room.delegates.add(delegate: recorder)

        let packet = Livekit_UserPacket.with {
            $0.participantIdentity = legacyIdentity
            $0.payload = Data("hello".utf8)
            $0.topic = "greetings"
        }
        room.engine(room,
                    didReceiveUserPacket: packet,
                    participantIdentity: outerIdentity,
                    encryptionType: .none)

        return try await recorder.wait()
    }
}
