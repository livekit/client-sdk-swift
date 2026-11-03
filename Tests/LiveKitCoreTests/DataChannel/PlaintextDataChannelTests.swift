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

@Suite(.tags(.dataChannel, .e2ee))
struct PlaintextDataChannelTests {
    @Test func plaintextUserPacketIsDeliveredWithEncryptionEnabled() async throws {
        let pair = DataChannelPair()
        let manager = E2EEManager(options: .sharedKey("test-key"))
        let receiver = PlaintextReceiver()
        pair.set(e2eeManager: manager)
        pair.delegates.add(delegate: receiver)
        try #require(manager.isDataChannelEncryptionEnabled)
        let packet = Livekit_DataPacket.with {
            $0.participantSid = "PA_sender"
            $0.participantIdentity = "sender"
            $0.user = .with { $0.payload = Data("hello".utf8) }
        }

        try pair.handle(received: packet.serializedData(), isReliable: true)
        await pair.delegates.notifyAsync { _ in }

        #expect(receiver.packets.copy() == [packet])
        #expect(receiver.encryptionTypes.copy() == [.none])
        #expect(receiver.errors.copy().isEmpty)
    }
}

private final class PlaintextReceiver: DataChannelDelegate {
    let packets = StateSync<[Livekit_DataPacket]>([])
    let encryptionTypes = StateSync<[EncryptionType]>([])
    let errors = StateSync<[LiveKitError]>([])

    func dataChannel(_: DataChannelPair, didReceiveDataPacket packet: Livekit_DataPacket, serialized _: Data?, encryptionType: EncryptionType) {
        packets.mutate { $0.append(packet) }
        encryptionTypes.mutate { $0.append(encryptionType) }
    }

    func dataChannel(_: DataChannelPair, didFailToDecryptDataPacket _: Livekit_DataPacket, error: LiveKitError) {
        errors.mutate { $0.append(error) }
    }
}
