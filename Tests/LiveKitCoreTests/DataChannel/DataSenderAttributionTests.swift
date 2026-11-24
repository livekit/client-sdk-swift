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

/// Who a received data packet is attributed to.
///
/// The native core reads the sender from the server-stamped packet identity and hands Swift only
/// that typed identity, so a forged inner identity cannot reach Swift through the public API. The
/// end-to-end case proves attribution to the server-stamped sender on the wire; the unit case pins
/// the Swift mapping from a core identity that names no known participant.
@Suite(.serialized, .tags(.dataChannel, .e2ee))
struct DataSenderAttributionTests {
    /// The sender's data is attributed to it in the room and participant delegates, and not to a
    /// bystander. Encrypted packets should report `.gcm`; the native core omits that metadata
    /// today (API_COV), so the encrypted case keeps that expectation as a known failing regression.
    @Test(.tags(.e2e), arguments: [false, true])
    func serverStampedSenderWins(encrypted: Bool) async throws {
        let receiver = DataReceiver()
        let options = [
            RoomTestingOptions(identity: "A", isE2eeEnabled: encrypted, canPublishData: true),
            RoomTestingOptions(identity: "B", isE2eeEnabled: encrypted, canPublishData: true),
            RoomTestingOptions(delegate: receiver, identity: "R", isE2eeEnabled: encrypted, canSubscribe: true),
        ]
        try await TestEnvironment.withRooms(options) { rooms in
            let observer = rooms[2]
            let a = try #require(observer.remoteParticipants[Participant.Identity(from: "A")])
            let b = try #require(observer.remoteParticipants[Participant.Identity(from: "B")])
            let aReceiver = DataReceiver()
            let bReceiver = DataReceiver()
            a.add(delegate: aReceiver)
            b.add(delegate: bReceiver)

            try await rooms[0].localParticipant.publish(data: Data("payload".utf8), options: DataPublishOptions(topic: "topic", reliable: true))
            try await poll(timeout: 15, for: "the payload at the observer") {
                !receiver.deliveries.copy().isEmpty && !aReceiver.deliveries.copy().isEmpty
            }

            let expected = Delivery(sender: "A", payload: Data("payload".utf8), topic: "topic", encryptionType: encrypted ? .gcm : .none)
            #expect(receiver.deliveries.copy().map(\.sender) == ["A"])
            #expect(aReceiver.deliveries.copy().map(\.sender) == ["A"])
            #expect(bReceiver.deliveries.copy().isEmpty)
            #expect(receiver.deliveries.copy() == [expected])
        }
    }

    /// A core identity that is empty or names nobody in the room reaches the room delegate without a
    /// participant, and no participant delegate.
    @Test(arguments: ["", "H"])
    func unknownSenderIsUnattributed(identity: String) async {
        let room = Room()
        room._state.onDidMutate = nil
        let a = RemoteParticipant(info: participant("A"), publications: [], room: room, connectionState: .connected)
        let b = RemoteParticipant(info: participant("B"), publications: [], room: room, connectionState: .connected)
        room._state.mutate {
            $0.remoteParticipants = [Participant.Identity(from: "A"): a, Participant.Identity(from: "B"): b]
            $0.connectionState = .connected
        }
        let roomReceiver = DataReceiver()
        let aReceiver = DataReceiver()
        let bReceiver = DataReceiver()
        room.add(delegate: roomReceiver)
        a.add(delegate: aReceiver)
        b.add(delegate: bReceiver)

        room.didReceive(data: Data("payload".utf8), topic: "topic", participantIdentity: identity)
        await room.delegates.notifyAsync { _ in }
        await a.delegates.notifyAsync { _ in }
        await b.delegates.notifyAsync { _ in }

        #expect(roomReceiver.deliveries.copy() == [Delivery(sender: nil, payload: Data("payload".utf8), topic: "topic", encryptionType: .none)])
        #expect(aReceiver.deliveries.copy().isEmpty)
        #expect(bReceiver.deliveries.copy().isEmpty)
    }

    private func participant(_ identity: String) -> NativeParticipant {
        NativeParticipant(identity: identity, sid: "PA_\(identity)", isLocal: false, name: "", state: .active, kind: .standard,
                          kindDetails: [], metadata: "", attributes: [:], isSpeaking: false, audioLevel: 0, connectionQuality: .good,
                          joinedAt: 0, permission: nil, isEncrypted: false, disconnectReason: .unknownReason, clientProtocol: 2,
                          capabilities: nil)
    }
}

private struct Delivery: Equatable {
    let sender: String?
    let payload: Data
    let topic: String
    let encryptionType: LiveKit.EncryptionType
}

private final class DataReceiver: RoomDelegate, ParticipantDelegate, Sendable {
    let deliveries = StateSync([Delivery]())

    func room(_: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: LiveKit.EncryptionType) {
        record(participant, data: data, topic: topic, encryptionType: encryptionType)
    }

    func participant(_ participant: RemoteParticipant, didReceiveData data: Data, forTopic topic: String, encryptionType: LiveKit.EncryptionType) {
        record(participant, data: data, topic: topic, encryptionType: encryptionType)
    }

    private func record(_ participant: RemoteParticipant?, data: Data, topic: String, encryptionType: LiveKit.EncryptionType) {
        let delivery = Delivery(sender: participant?.identity?.stringValue, payload: data, topic: topic, encryptionType: encryptionType)
        deliveries.mutate { $0.append(delivery) }
    }
}
