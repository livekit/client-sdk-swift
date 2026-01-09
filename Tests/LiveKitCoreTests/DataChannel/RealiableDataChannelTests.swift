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

class RealiableDataChannelTests: LKTestCase, @unchecked Sendable {
    var receivedExpectation: XCTestExpectation!
    var receivedData: Data!

    override func setUp() {
        super.setUp()
        receivedData = Data()
    }

    func testReliableRetry() async throws {
        let iterations = 128
        receivedExpectation = expectation(description: "Data received")
        receivedExpectation.expectedFulfillmentCount = iterations

        let testString = "abcdefghijklmnopqrstuvwxyz🔥"
        let testData = String(repeating: testString, count: 1024).data(using: .utf8)!

        try await withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(delegate: self, canSubscribe: true),
        ]) { rooms in
            let sending = rooms[0]
            let receiving = rooms[1]
            let remoteIdentity = try XCTUnwrap(sending.remoteParticipants.keys.first)

            Task {
                try await Task.sleep(nanoseconds: 200_000_000) // 200 ms
                try await sending.startReconnect(reason: .debug)
            }
            Task {
                try await Task.sleep(nanoseconds: 400_000_000) // 400 ms
                try await receiving.startReconnect(reason: .debug)
            }

            for _ in 0 ..< iterations {
                let userPacket = Livekit_UserPacket.with {
                    $0.payload = testData
                    $0.destinationIdentities = [remoteIdentity.stringValue]
                }

                try await sending.send(userPacket: userPacket, kind: .reliable)
                try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            }
        }

        await fulfillment(of: [receivedExpectation], timeout: 10)

        let receivedString = try XCTUnwrap(String(data: receivedData, encoding: .utf8))
        XCTAssertEqual(receivedString.count, testString.count * 1024 * iterations, "Corrupted or duplicated data")
    }
}

extension RealiableDataChannelTests: RoomDelegate {
    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String, encryptionType _: EncryptionType) {
        receivedData.append(data)
        receivedExpectation.fulfill()
    }
}
