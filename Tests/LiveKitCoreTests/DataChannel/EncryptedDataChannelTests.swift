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

@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import LiveKitWebRTC

class EncryptedDataChannelTests: LKTestCase, @unchecked Sendable {
    var receivedDataExpectation: XCTestExpectation!
    var receivedData: Data!
    var decryptionErrorExpectation: XCTestExpectation!
    var lastDecryptionError: Error?

    override func setUp() {
        super.setUp()
        receivedData = Data()
        lastDecryptionError = nil
    }

    func testEncryptionWithSharedKey() async throws {
        receivedDataExpectation = expectation(description: "Encrypted data received")
        let testMessage = "Hello, encrypted world!"
        let testData = testMessage.data(using: .utf8)!

        try await withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(delegate: self, canSubscribe: true),
        ]) { rooms in
            let sender = rooms[0]
            let remoteIdentity = try XCTUnwrap(sender.remoteParticipants.keys.first)

            let userPacket = Livekit_UserPacket.with {
                $0.payload = testData
                $0.destinationIdentities = [remoteIdentity.stringValue]
            }

            try await sender.send(userPacket: userPacket, kind: .reliable)

            await self.fulfillment(of: [self.receivedDataExpectation], timeout: 5)

            let receivedMessage = String(data: self.receivedData!, encoding: .utf8)
            XCTAssertEqual(receivedMessage, testMessage, "Received message should match sent message")
        }
    }

    func testEncryptionWithPerParticipantKeys() async throws {
        receivedDataExpectation = expectation(description: "Encrypted data with per-participant keys received")
        let testMessage = "Hello, per-participant encrypted world!"
        let testData = testMessage.data(using: .utf8)!

        let senderKeyProvider = BaseKeyProvider(isSharedKey: false)
        let receiverKeyProvider = BaseKeyProvider(isSharedKey: false)

        let senderKey = "sender-secret-key-123"
        let receiverKey = "receiver-secret-key-456"

        try await withRooms([
            RoomTestingOptions(
                encryptionOptions: EncryptionOptions(keyProvider: senderKeyProvider), canPublishData: true
            ),
            RoomTestingOptions(
                delegate: self,
                encryptionOptions: EncryptionOptions(keyProvider: receiverKeyProvider), canSubscribe: true
            ),
        ]) { rooms in
            let sender = rooms[0]
            let receiver = rooms[1]

            let senderIdentity = try XCTUnwrap(sender.localParticipant.identity?.stringValue)
            let receiverIdentity = try XCTUnwrap(receiver.localParticipant.identity?.stringValue)

            senderKeyProvider.setKey(key: senderKey, participantId: senderIdentity)
            senderKeyProvider.setKey(key: receiverKey, participantId: receiverIdentity)
            receiverKeyProvider.setKey(key: senderKey, participantId: senderIdentity)
            receiverKeyProvider.setKey(key: receiverKey, participantId: receiverIdentity)

            let remoteIdentity = try XCTUnwrap(sender.remoteParticipants.keys.first)

            let userPacket = Livekit_UserPacket.with {
                $0.payload = testData
                $0.destinationIdentities = [remoteIdentity.stringValue]
            }

            try await sender.send(userPacket: userPacket, kind: .reliable)

            await self.fulfillment(of: [self.receivedDataExpectation], timeout: 5)

            let receivedMessage = String(data: self.receivedData!, encoding: .utf8)
            XCTAssertEqual(receivedMessage, testMessage, "Received message should match sent message with per-participant keys")
        }
    }

    func testDecryptionFailureWithSharedKey() async throws {
        decryptionErrorExpectation = expectation(description: "Decryption error occurred")
        let testMessage = "This should fail to decrypt!"
        let testData = testMessage.data(using: .utf8)!

        let senderKey = "sender-shared-key-123"
        let receiverKey = "receiver-shared-key-456"

        let senderKeyProvider = BaseKeyProvider(isSharedKey: true, sharedKey: senderKey)
        let receiverKeyProvider = BaseKeyProvider(isSharedKey: true, sharedKey: receiverKey)

        try await withRooms([
            RoomTestingOptions(
                encryptionOptions: EncryptionOptions(keyProvider: senderKeyProvider),
                canPublishData: true
            ),
            RoomTestingOptions(
                delegate: self,
                encryptionOptions: EncryptionOptions(keyProvider: receiverKeyProvider),
                canSubscribe: true
            ),
        ]) { rooms in
            let sender = rooms[0]
            let remoteIdentity = try XCTUnwrap(sender.remoteParticipants.keys.first)

            let userPacket = Livekit_UserPacket.with {
                $0.payload = testData
                $0.destinationIdentities = [remoteIdentity.stringValue]
            }

            try await sender.send(userPacket: userPacket, kind: .reliable)

            await self.fulfillment(of: [self.decryptionErrorExpectation], timeout: 5)

            XCTAssertNotNil(self.lastDecryptionError, "Decryption error should have occurred")
            XCTAssert(self.receivedData.isEmpty, "No data should be received when decryption fails")
        }
    }

    func testDecryptionFailureWithPerParticipantKeys() async throws {
        decryptionErrorExpectation = expectation(description: "Decryption error occurred with per-participant keys")
        let testMessage = "This should fail to decrypt with per-participant keys!"
        let testData = testMessage.data(using: .utf8)!

        let senderKeyProvider = BaseKeyProvider(isSharedKey: false)
        let receiverKeyProvider = BaseKeyProvider(isSharedKey: false)

        let senderKey = "sender-secret-key-123"
        let wrongSenderKey = "wrong-secret-key-999"
        let receiverKey = "receiver-secret-key-456"

        try await withRooms([
            RoomTestingOptions(
                encryptionOptions: EncryptionOptions(keyProvider: senderKeyProvider),
                canPublishData: true
            ),
            RoomTestingOptions(
                delegate: self,
                encryptionOptions: EncryptionOptions(keyProvider: receiverKeyProvider),
                canSubscribe: true
            ),
        ]) { rooms in
            let sender = rooms[0]
            let receiver = rooms[1]

            let senderIdentity = try XCTUnwrap(sender.localParticipant.identity?.stringValue)
            let receiverIdentity = try XCTUnwrap(receiver.localParticipant.identity?.stringValue)

            senderKeyProvider.setKey(key: senderKey, participantId: senderIdentity)
            senderKeyProvider.setKey(key: receiverKey, participantId: receiverIdentity)
            receiverKeyProvider.setKey(key: wrongSenderKey, participantId: senderIdentity)
            receiverKeyProvider.setKey(key: receiverKey, participantId: receiverIdentity)

            let remoteIdentity = try XCTUnwrap(sender.remoteParticipants.keys.first)

            let userPacket = Livekit_UserPacket.with {
                $0.payload = testData
                $0.destinationIdentities = [remoteIdentity.stringValue]
            }

            try await sender.send(userPacket: userPacket, kind: .reliable)

            await self.fulfillment(of: [self.decryptionErrorExpectation], timeout: 5)

            XCTAssertNotNil(self.lastDecryptionError, "Decryption error should have occurred with mismatched per-participant keys")
            XCTAssert(self.receivedData.isEmpty, "No data should be received when per-participant key decryption fails")
        }
    }

    func testKeyRatcheting() async throws {
        receivedDataExpectation = expectation(description: "Data received after automatic key ratcheting")
        let testMessage = "Hello with automatic ratcheting!"
        let testData = testMessage.data(using: .utf8)!

        let senderKeyProvider = BaseKeyProvider(options: KeyProviderOptions(
            sharedKey: true,
            ratchetWindowSize: 2
        ))
        let receiverKeyProvider = BaseKeyProvider(options: KeyProviderOptions(
            sharedKey: true,
            ratchetWindowSize: 2
        ))

        let initialKey = "initial-key-\(UUID().uuidString)"
        senderKeyProvider.setKey(key: initialKey)
        receiverKeyProvider.setKey(key: initialKey)

        try await withRooms([
            RoomTestingOptions(
                encryptionOptions: EncryptionOptions(keyProvider: senderKeyProvider),
                canPublishData: true
            ),
            RoomTestingOptions(
                delegate: self,
                encryptionOptions: EncryptionOptions(keyProvider: receiverKeyProvider),
                canSubscribe: true
            ),
        ]) { rooms in
            let sender = rooms[0]
            let remoteIdentity = try XCTUnwrap(sender.remoteParticipants.keys.first)

            // Sender ratchets their key forward
            let ratchetedKey = senderKeyProvider.ratchetKey()
            XCTAssertNotNil(ratchetedKey, "Sender key ratcheting should succeed")

            // Export keys to verify they're different
            let senderExportedKey = senderKeyProvider.exportKey()
            let receiverExportedKey = receiverKeyProvider.exportKey()
            XCTAssertNotEqual(senderExportedKey, receiverExportedKey, "Keys should be different after sender ratchets")

            // Send encrypted data with the ratcheted key
            let userPacket = Livekit_UserPacket.with {
                $0.payload = testData
                $0.destinationIdentities = [remoteIdentity.stringValue]
            }

            try await sender.send(userPacket: userPacket, kind: .reliable)

            // Receiver should automatically ratchet and decrypt successfully
            await self.fulfillment(of: [self.receivedDataExpectation], timeout: 5)

            let receivedMessage = String(data: self.receivedData!, encoding: .utf8)
            XCTAssertEqual(receivedMessage, testMessage, "Message should be received after automatic key ratcheting")
        }
    }

    func testMultipleKeysInKeyRing() async throws {
        receivedDataExpectation = expectation(description: "Data received with multiple keys in key ring")
        let testMessage = "Hello with multiple keys in key ring!"
        let testData = testMessage.data(using: .utf8)!

        let senderKeyProvider = BaseKeyProvider(options: KeyProviderOptions(
            sharedKey: true,
            keyRingSize: 2
        ))
        let receiverKeyProvider = BaseKeyProvider(options: KeyProviderOptions(
            sharedKey: true,
            keyRingSize: 2
        ))

        let key1 = "secret-key-1"
        let key2 = "secret-key-2"
        senderKeyProvider.setKey(key: key1, index: 0)
        senderKeyProvider.setKey(key: key2, index: 1)
        receiverKeyProvider.setKey(key: key1, index: 0)
        receiverKeyProvider.setKey(key: key2, index: 1)

        try await withRooms([
            RoomTestingOptions(
                encryptionOptions: EncryptionOptions(keyProvider: senderKeyProvider),
                canPublishData: true
            ),
            RoomTestingOptions(
                delegate: self,
                encryptionOptions: EncryptionOptions(keyProvider: receiverKeyProvider),
                canSubscribe: true
            ),
        ]) { rooms in
            let sender = rooms[0]
            let remoteIdentity = try XCTUnwrap(sender.remoteParticipants.keys.first)

            senderKeyProvider.setCurrentKeyIndex(1)

            let userPacket = Livekit_UserPacket.with {
                $0.payload = testData
                $0.destinationIdentities = [remoteIdentity.stringValue]
            }

            try await sender.send(userPacket: userPacket, kind: .reliable)

            await self.fulfillment(of: [self.receivedDataExpectation], timeout: 5)

            let receivedMessage = String(data: self.receivedData!, encoding: .utf8)
            XCTAssertEqual(receivedMessage, testMessage, "Message should be received with multiple keys in key ring")
        }
    }
}

// MARK: - RoomDelegate

extension EncryptedDataChannelTests: RoomDelegate {
    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String, encryptionType _: EncryptionType) {
        receivedData = data
        receivedDataExpectation?.fulfill()
    }

    func room(_: Room, didFailToDecryptDataWithEror error: LiveKitError) {
        lastDecryptionError = error
        decryptionErrorExpectation?.fulfill()
    }
}
