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
import LiveKitWebRTC
import Testing

@Suite(.tags(.dataChannel))
struct DataSenderAttributionTests {
    @Test(arguments: [("A", "B"), ("", "B"), ("A", "")], [false, true])
    func receivedUserData(identities: (outer: String, inner: String), encrypted: Bool) async throws {
        let room = Room()
        room._state.onDidMutate = nil
        let participants = ["A", "B"].map { identity in
            RemoteParticipant(info: .with {
                $0.identity = identity
                $0.sid = "PA_\(identity)"
            }, room: room, connectionState: .connected)
        }
        let sender = try #require(participants.first)
        let other = try #require(participants.last)
        room._state.mutate {
            $0.remoteParticipants = Dictionary(uniqueKeysWithValues: participants.compactMap { participant in
                participant.identity.map { ($0, participant) }
            })
            $0.connectionState = .connected
        }

        let encryptionType: EncryptionType = encrypted ? .gcm : .none
        let roomReceiver = DataReceiver(encryptionType: encryptionType)
        let senderReceiver = DataReceiver(encryptionType: encryptionType)
        let otherReceiver = DataReceiver(encryptionType: encryptionType)
        room.add(delegate: roomReceiver)
        sender.add(delegate: senderReceiver)
        other.add(delegate: otherReceiver)

        let pair = DataChannelPair(delegate: room)
        let userPacket = Livekit_UserPacket.with {
            $0.participantIdentity = identities.inner
            $0.payload = Data("payload".utf8)
            $0.topic = "topic"
        }
        var packet = Livekit_DataPacket.with {
            $0.participantIdentity = identities.outer
            $0.user = userPacket
        }
        if encrypted {
            packet = try encrypt(packet, for: pair)
        }

        try pair.handle(received: packet.serializedData(), isReliable: true)
        await pair.delegates.notifyAsync { _ in }
        await room.delegates.notifyAsync { _ in }
        await sender.delegates.notifyAsync { _ in }
        await other.delegates.notifyAsync { _ in }

        #expect(roomReceiver.identities.copy() == [identities.outer.isEmpty ? nil : "A"])
        #expect(senderReceiver.identities.copy() == (identities.outer.isEmpty ? [] : ["A"]))
        #expect(otherReceiver.identities.copy().isEmpty)
    }

    private func encrypt(_ packet: Livekit_DataPacket, for pair: DataChannelPair) throws -> Livekit_DataPacket {
        let keys = BaseKeyProvider(options: KeyProviderOptions(sharedKey: true))
        keys.setKey(key: "sender-attribution-test-key")
        let manager = E2EEManager(options: EncryptionOptions(keyProvider: keys))
        manager.addDataChannelCryptor()
        pair.set(e2eeManager: manager)

        let cryptor = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: keys.rtcKeyProvider))
        let payload = Livekit_EncryptedPacketPayload.with { $0.user = packet.user }
        let payloadData = try payload.serializedData()
        let ciphertext = try #require(cryptor.encrypt("A", keyIndex: 0, data: payloadData))
        return packet.modifying { $0.encryptedPacket = Livekit_EncryptedPacket(rtcPacket: ciphertext) }
    }
}

private final class DataReceiver: RoomDelegate, ParticipantDelegate, Sendable {
    let identities = StateSync([String?]())
    let encryptionType: EncryptionType

    init(encryptionType: EncryptionType) {
        self.encryptionType = encryptionType
    }

    func room(_: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        record(participant, data: data, topic: topic, encryptionType: encryptionType)
    }

    func participant(_ participant: RemoteParticipant, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        record(participant, data: data, topic: topic, encryptionType: encryptionType)
    }

    private func record(_ participant: RemoteParticipant?, data: Data, topic: String, encryptionType: EncryptionType) {
        #expect(data == Data("payload".utf8))
        #expect(topic == "topic")
        #expect(encryptionType == self.encryptionType)
        identities.mutate { $0.append(participant?.identity?.stringValue) }
    }
}
