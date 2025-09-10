/*
 * Copyright 2025 LiveKit
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
import LiveKitWebRTC
import XCTest

class EncryptedDataChannelTests: LKTestCase, @unchecked Sendable {
    var receivedDataExpectation: XCTestExpectation!
    var receivedData: Data?
    var decryptionErrorExpectation: XCTestExpectation!
    var lastDecryptionError: Error?

    override func setUp() {
        super.setUp()
        receivedData = nil
        lastDecryptionError = nil

        receivedDataExpectation = expectation(description: "Data received")
    }

    // MARK: - Basic Encryption/Decryption Tests with withRooms

    func testEncryptionDisabled() async throws {
        let testMessage = "Hello, unencrypted world!"
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

    func testEncryptionWithSharedKey() async throws {
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
}

// MARK: - RoomDelegate Implementation

extension EncryptedDataChannelTests: RoomDelegate {
    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String) {
        receivedData = data
        receivedDataExpectation?.fulfill()
    }

    func room(_: Room, didFailToDecryptDataPacket _: Livekit_DataPacket, error: Error) {
        lastDecryptionError = error
        decryptionErrorExpectation?.fulfill()
    }
}
