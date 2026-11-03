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

@Suite(.tags(.rpc))
struct RpcEncryptionTests {
    @Test func v1EncryptedRequestReportsGcm() async throws {
        let manager = try RpcPacketEncryption()
        let payload = try #require(Livekit_EncryptedPacketPayload(dataPacket: requestPacket))
        let encrypted = try #require(manager.cryptor.encrypt("caller", keyIndex: 0, data: payload.serializedData()))
        let packet = requestPacket.modifying { $0.encryptedPacket = Livekit_EncryptedPacket(rtcPacket: encrypted) }

        try await expectV1EncryptionType(.gcm, packet: packet, manager: manager)
    }

    @Test func v1PlaintextRequestReportsNone() async throws {
        try await expectV1EncryptionType(.none, packet: requestPacket, manager: RpcPacketEncryption())
    }

    private var requestPacket: Livekit_DataPacket {
        .with {
            $0.participantIdentity = "caller"
            $0.rpcRequest = .with {
                $0.id = "request"
                $0.method = "sensitive"
                $0.payload = "payload"
                $0.version = 1
                $0.responseTimeoutMs = 8000
            }
        }
    }

    private func expectV1EncryptionType(_ encryptionType: EncryptionType, packet: Livekit_DataPacket, manager: RpcPacketEncryption) async throws {
        let room = Room()
        await room.rpcServer.attach(to: room)
        let received = AsyncCompleter<EncryptionType>(label: "RPC encryption type", defaultTimeout: 5)
        try await room.registerRpcMethod("sensitive") { data in
            received.resume(returning: data.encryptionType)
            return "response"
        }
        let pair = DataChannelPair()
        pair.set(e2eeManager: manager)
        pair.delegates.add(delegate: room)
        try #require(manager.isDataChannelEncryptionEnabled)

        try pair.handle(received: packet.serializedData(), isReliable: true)

        #expect(try await received.wait() == encryptionType)
    }

    @Test(arguments: [EncryptionType.gcm, .none])
    func v2RequestReportsStreamEncryptionType(encryptionType: EncryptionType) async throws {
        let room = Room()
        await room.rpcServer.attach(to: room)
        let received = StateSync<EncryptionType?>(nil)
        try await room.registerRpcMethod("sensitive") { data in
            received.mutate { $0 = data.encryptionType }
            return "response"
        }
        let reader = StubTextStreamReader(
            topic: RpcStreamTopic.request,
            attributes: [
                RpcStreamAttribute.requestId: "request",
                RpcStreamAttribute.method: "sensitive",
                RpcStreamAttribute.timeoutMs: "8000",
                RpcStreamAttribute.version: RPC_STREAM_VERSION,
            ],
            result: .success("payload"),
            encryptionType: encryptionType,
        )

        await room.rpcServer.handleIncomingRequestStream(reader: reader, callerIdentity: Participant.Identity(from: "caller"))

        #expect(received.copy() == encryptionType)
    }
}

private final class RpcPacketEncryption: E2EEManager, @unchecked Sendable {
    let cryptor: LKRTCDataPacketCryptor

    init() throws {
        let keyProvider = BaseKeyProvider(isSharedKey: true, sharedKey: "rpc-test-key")
        cryptor = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: keyProvider.rtcKeyProvider))
        super.init(options: EncryptionOptions(keyProvider: keyProvider))
    }

    override func handle(encryptedData: LKRTCEncryptedPacket, participantIdentity: String) throws -> Data {
        try #require(cryptor.decrypt(participantIdentity, encryptedPacket: encryptedData))
    }
}
