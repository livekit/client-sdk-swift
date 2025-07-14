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
import XCTest

class DataChannelTests: LKTestCase, @unchecked Sendable {
    var receivedExpectation: XCTestExpectation!
    var receivedData: Data!

    override func setUp() async throws {
        receivedExpectation = expectation(description: "Data received")
        receivedData = Data()
    }

    func testReliableRetry() async throws {
        let testData = ["abc", "def", "ghi", "jkl", "mno", "pqr", "stu", "vwx", "yz", "🔥"].map { $0.data(using: .utf8)! }

        receivedExpectation.expectedFulfillmentCount = testData.count
        receivedExpectation.assertForOverFulfill = false

        try await withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(delegate: self, canSubscribe: true),
        ]) { rooms in
            let sending = rooms[0]
            let receiving = rooms[1]
            let remoteIdentity = try XCTUnwrap(sending.remoteParticipants.keys.first)

            Task { try await sending.startReconnect(reason: .debug) }
            Task { try await receiving.startReconnect(reason: .debug) }

            for data in testData {
                let userPacket = Livekit_UserPacket.with {
                    $0.payload = data
                    $0.destinationIdentities = [remoteIdentity.stringValue]
                }

                try await sending.send(userPacket: userPacket, kind: .reliable)
                try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            }
        }

        await fulfillment(of: [receivedExpectation], timeout: 5)

        let receivedString = try XCTUnwrap(String(data: receivedData, encoding: .utf8))
        XCTAssertEqual(receivedString, "abcdefghijklmnopqrstuvwxyz🔥") // no duplicates
    }
}

extension DataChannelTests: RoomDelegate {
    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String) {
        receivedData.append(data)
        receivedExpectation.fulfill()
    }
}
