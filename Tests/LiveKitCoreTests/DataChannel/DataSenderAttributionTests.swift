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

@Suite(.tags(.dataChannel, .e2ee))
struct DataSenderAttributionTests {
    @Test(arguments: ["B", ""], [false, true])
    func serverStampedSenderWins(inner: String, encrypted: Bool) async throws {
        let deliveries = try await receive(outer: "A", inner: inner, encrypted: encrypted)
        let expected = expectedDelivery(sender: "A", encrypted: encrypted)
        #expect(deliveries.room == [expected])
        #expect(deliveries.a == [expected])
        #expect(deliveries.b.isEmpty)
    }

    @Test(arguments: ["", "H"], [false, true])
    func unknownSenderIsUnattributed(outer: String, encrypted: Bool) async throws {
        let deliveries = try await receive(outer: outer, inner: "B", encrypted: encrypted)
        let expected = expectedDelivery(sender: nil, encrypted: encrypted)
        #expect(deliveries.room == [expected])
        #expect(deliveries.a.isEmpty)
        #expect(deliveries.b.isEmpty)
    }

    private func receive(outer: String, inner: String, encrypted: Bool,
                         sourceLocation: SourceLocation = #_sourceLocation) async throws -> ReceivedDeliveries
    {
        let room = Room()
        // Avoid connection-state callbacks that initialize the lazy local participant.
        room._state.onDidMutate = nil
        let a = RemoteParticipant(info: .with {
            $0.identity = "A"
            $0.sid = "PA_A"
        }, room: room, connectionState: .connected)
        let b = RemoteParticipant(info: .with {
            $0.identity = "B"
            $0.sid = "PA_B"
        }, room: room, connectionState: .connected)
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
        let pair = DataChannelPair(delegate: room)
        var packet = Livekit_DataPacket.with {
            $0.participantIdentity = outer
            $0.user = .with {
                $0.participantIdentity = inner
                $0.payload = Data("payload".utf8)
                $0.topic = "topic"
            }
        }
        if encrypted {
            let keys = BaseKeyProvider(options: KeyProviderOptions(sharedKey: true))
            keys.setKey(key: "sender-attribution-test-key")
            let manager = E2EEManager(options: EncryptionOptions(keyProvider: keys))
            manager.addDataChannelCryptor()
            pair.set(e2eeManager: manager)
            let cryptor = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: keys.rtcKeyProvider), sourceLocation: sourceLocation)
            packet = try encrypt(packet, for: cryptor, sourceLocation: sourceLocation)
        }
        try pair.handle(received: packet.serializedData(), isReliable: true)
        await pair.delegates.notifyAsync { _ in }
        await room.delegates.notifyAsync { _ in }
        await a.delegates.notifyAsync { _ in }
        await b.delegates.notifyAsync { _ in }
        return ReceivedDeliveries(room: roomReceiver.deliveries.copy(), a: aReceiver.deliveries.copy(), b: bReceiver.deliveries.copy())
    }

    private func encrypt(_ packet: Livekit_DataPacket, for cryptor: LKRTCDataPacketCryptor,
                         sourceLocation: SourceLocation = #_sourceLocation) throws -> Livekit_DataPacket
    {
        let payload = Livekit_EncryptedPacketPayload.with { $0.user = packet.user }
        let payloadData = try payload.serializedData()
        let ciphertext = try #require(cryptor.encrypt("A", keyIndex: 0, data: payloadData), sourceLocation: sourceLocation)
        return packet.modifying { $0.encryptedPacket = Livekit_EncryptedPacket(rtcPacket: ciphertext) }
    }

    private func expectedDelivery(sender: String?, encrypted: Bool) -> Delivery {
        Delivery(sender: sender, payload: Data("payload".utf8), topic: "topic", encryptionType: encrypted ? .gcm : .none)
    }
}

private struct ReceivedDeliveries {
    let room: [Delivery]
    let a: [Delivery]
    let b: [Delivery]
}

private struct Delivery: Equatable {
    let sender: String?
    let payload: Data
    let topic: String
    let encryptionType: EncryptionType
}

private final class DataReceiver: RoomDelegate, ParticipantDelegate, Sendable {
    let deliveries = StateSync([Delivery]())

    func room(_: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        record(participant, data: data, topic: topic, encryptionType: encryptionType)
    }

    func participant(_ participant: RemoteParticipant, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        record(participant, data: data, topic: topic, encryptionType: encryptionType)
    }

    private func record(_ participant: RemoteParticipant?, data: Data, topic: String, encryptionType: EncryptionType) {
        let delivery = Delivery(sender: participant?.identity?.stringValue, payload: data, topic: topic, encryptionType: encryptionType)
        deliveries.mutate { $0.append(delivery) }
    }
}
