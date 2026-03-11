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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import LiveKitWebRTC

@Suite(.serialized, .tags(.dataChannel, .e2e, .e2ee)) final class EncryptedDataChannelTests: @unchecked Sendable {
    var receivedData: Data = .init()
    var lastDecryptionError: Error?
    var onDataReceived: (() -> Void)?
    var onDecryptionError: (() -> Void)?

    @Test func encryptionWithSharedKey() async throws {
        let testMessage = "Hello, encrypted world!"
        let testData = try #require(testMessage.data(using: .utf8))

        try await confirmation("Encrypted data received") { confirm in
            self.receivedData = Data()
            self.onDataReceived = { confirm() }

            try await TestEnvironment.withRooms([
                RoomTestingOptions(canPublishData: true),
                RoomTestingOptions(delegate: self, canSubscribe: true),
            ]) { rooms in
                let sender = rooms[0]
                let remoteIdentity = try #require(sender.remoteParticipants.keys.first)

                let userPacket = Livekit_UserPacket.with {
                    $0.payload = testData
                    $0.destinationIdentities = [remoteIdentity.stringValue]
                }

                try await sender.send(userPacket: userPacket, kind: .reliable)

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            let receivedMessage = String(data: self.receivedData, encoding: .utf8)
            #expect(receivedMessage == testMessage, "Received message should match sent message")
        }
    }

    @Test func encryptionWithPerParticipantKeys() async throws {
        let testMessage = "Hello, per-participant encrypted world!"
        let testData = try #require(testMessage.data(using: .utf8))

        let senderKeyProvider = BaseKeyProvider(isSharedKey: false)
        let receiverKeyProvider = BaseKeyProvider(isSharedKey: false)

        let senderKey = "sender-secret-key-123"
        let receiverKey = "receiver-secret-key-456"

        try await confirmation("Encrypted data with per-participant keys received") { confirm in
            self.receivedData = Data()
            self.onDataReceived = { confirm() }

            try await TestEnvironment.withRooms([
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

                let senderIdentity = try #require(sender.localParticipant.identity?.stringValue)
                let receiverIdentity = try #require(receiver.localParticipant.identity?.stringValue)

                senderKeyProvider.setKey(key: senderKey, participantId: senderIdentity)
                senderKeyProvider.setKey(key: receiverKey, participantId: receiverIdentity)
                receiverKeyProvider.setKey(key: senderKey, participantId: senderIdentity)
                receiverKeyProvider.setKey(key: receiverKey, participantId: receiverIdentity)

                let remoteIdentity = try #require(sender.remoteParticipants.keys.first)

                let userPacket = Livekit_UserPacket.with {
                    $0.payload = testData
                    $0.destinationIdentities = [remoteIdentity.stringValue]
                }

                try await sender.send(userPacket: userPacket, kind: .reliable)

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            let receivedMessage = String(data: self.receivedData, encoding: .utf8)
            #expect(receivedMessage == testMessage, "Received message should match sent message with per-participant keys")
        }
    }

    @Test func decryptionFailureWithSharedKey() async throws {
        let testMessage = "This should fail to decrypt!"
        let testData = try #require(testMessage.data(using: .utf8))

        let senderKey = "sender-shared-key-123"
        let receiverKey = "receiver-shared-key-456"

        let senderKeyProvider = BaseKeyProvider(isSharedKey: true, sharedKey: senderKey)
        let receiverKeyProvider = BaseKeyProvider(isSharedKey: true, sharedKey: receiverKey)

        try await confirmation("Decryption error occurred") { confirm in
            self.receivedData = Data()
            self.lastDecryptionError = nil
            self.onDecryptionError = { confirm() }

            try await TestEnvironment.withRooms([
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
                let remoteIdentity = try #require(sender.remoteParticipants.keys.first)

                let userPacket = Livekit_UserPacket.with {
                    $0.payload = testData
                    $0.destinationIdentities = [remoteIdentity.stringValue]
                }

                try await sender.send(userPacket: userPacket, kind: .reliable)

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            #expect(self.lastDecryptionError != nil, "Decryption error should have occurred")
            #expect(self.receivedData.isEmpty, "No data should be received when decryption fails")
        }
    }

    @Test func decryptionFailureWithPerParticipantKeys() async throws {
        let testMessage = "This should fail to decrypt with per-participant keys!"
        let testData = try #require(testMessage.data(using: .utf8))

        let senderKeyProvider = BaseKeyProvider(isSharedKey: false)
        let receiverKeyProvider = BaseKeyProvider(isSharedKey: false)

        let senderKey = "sender-secret-key-123"
        let wrongSenderKey = "wrong-secret-key-999"
        let receiverKey = "receiver-secret-key-456"

        try await confirmation("Decryption error occurred with per-participant keys") { confirm in
            self.receivedData = Data()
            self.lastDecryptionError = nil
            self.onDecryptionError = { confirm() }

            try await TestEnvironment.withRooms([
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

                let senderIdentity = try #require(sender.localParticipant.identity?.stringValue)
                let receiverIdentity = try #require(receiver.localParticipant.identity?.stringValue)

                senderKeyProvider.setKey(key: senderKey, participantId: senderIdentity)
                senderKeyProvider.setKey(key: receiverKey, participantId: receiverIdentity)
                receiverKeyProvider.setKey(key: wrongSenderKey, participantId: senderIdentity)
                receiverKeyProvider.setKey(key: receiverKey, participantId: receiverIdentity)

                let remoteIdentity = try #require(sender.remoteParticipants.keys.first)

                let userPacket = Livekit_UserPacket.with {
                    $0.payload = testData
                    $0.destinationIdentities = [remoteIdentity.stringValue]
                }

                try await sender.send(userPacket: userPacket, kind: .reliable)

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            #expect(self.lastDecryptionError != nil, "Decryption error should have occurred with mismatched per-participant keys")
            #expect(self.receivedData.isEmpty, "No data should be received when per-participant key decryption fails")
        }
    }

    @Test func keyRatcheting() async throws {
        let testMessage = "Hello with automatic ratcheting!"
        let testData = try #require(testMessage.data(using: .utf8))

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

        try await confirmation("Data received after automatic key ratcheting") { confirm in
            self.receivedData = Data()
            self.onDataReceived = { confirm() }

            try await TestEnvironment.withRooms([
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
                let remoteIdentity = try #require(sender.remoteParticipants.keys.first)

                // Sender ratchets their key forward
                let ratchetedKey = senderKeyProvider.ratchetKey()
                #expect(ratchetedKey != nil, "Sender key ratcheting should succeed")

                // Export keys to verify they're different
                let senderExportedKey = senderKeyProvider.exportKey()
                let receiverExportedKey = receiverKeyProvider.exportKey()
                #expect(senderExportedKey != receiverExportedKey, "Keys should be different after sender ratchets")

                // Send encrypted data with the ratcheted key
                let userPacket = Livekit_UserPacket.with {
                    $0.payload = testData
                    $0.destinationIdentities = [remoteIdentity.stringValue]
                }

                try await sender.send(userPacket: userPacket, kind: .reliable)

                // Receiver should automatically ratchet and decrypt successfully
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            let receivedMessage = String(data: self.receivedData, encoding: .utf8)
            #expect(receivedMessage == testMessage, "Message should be received after automatic key ratcheting")
        }
    }

    @Test func multipleKeysInKeyRing() async throws {
        let testMessage = "Hello with multiple keys in key ring!"
        let testData = try #require(testMessage.data(using: .utf8))

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

        try await confirmation("Data received with multiple keys in key ring") { confirm in
            self.receivedData = Data()
            self.onDataReceived = { confirm() }

            try await TestEnvironment.withRooms([
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
                let remoteIdentity = try #require(sender.remoteParticipants.keys.first)

                senderKeyProvider.setCurrentKeyIndex(1)

                let userPacket = Livekit_UserPacket.with {
                    $0.payload = testData
                    $0.destinationIdentities = [remoteIdentity.stringValue]
                }

                try await sender.send(userPacket: userPacket, kind: .reliable)

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            let receivedMessage = String(data: self.receivedData, encoding: .utf8)
            #expect(receivedMessage == testMessage, "Message should be received with multiple keys in key ring")
        }
    }
}

// MARK: - RoomDelegate

extension EncryptedDataChannelTests: RoomDelegate {
    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String, encryptionType _: EncryptionType) {
        receivedData = data
        onDataReceived?()
    }

    func room(_: Room, didFailToDecryptDataWithEror error: LiveKitError) {
        lastDecryptionError = error
        onDecryptionError?()
    }
}
