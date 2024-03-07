/*
 * Copyright 2024 LiveKit
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

#if !targetEnvironment(simulator)
// TODO: Make this work with iOS Simulator

class PublishTests: XCTestCase {
    let room = Room()

    override func setUp() async throws {
        let url = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"]
        let apiKey = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_API_KEY"]
        let apiSecret = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_API_SECRET"]

        guard let url else {
            XCTFail("LIVEKIT_TESTING_URL is nil")
            return
        }

        guard let apiKey else {
            XCTFail("LIVEKIT_TESTING_API_KEY is nil")
            return
        }

        guard let apiSecret else {
            XCTFail("LIVEKIT_TESTING_API_SECRET is nil")
            return
        }

        let tokenGenerator = TokenGenerator(apiKey: apiKey, apiSecret: apiSecret, identity: "test_publisher01")

        tokenGenerator.videoGrant = VideoGrant(room: "swiftsdk_test_01",
                                               roomJoin: true,
                                               canPublish: true)

        try await room.connect(url: url, token: tokenGenerator.sign())
    }

    override func tearDown() async throws {
        await room.disconnect()
    }

    func testResolveSid() async throws {
        XCTAssert(room.connectionState == .connected)

        let sid = try await room.sid()
        print("Room.sid(): \(String(describing: sid))")
        XCTAssert(sid.stringValue.starts(with: "RM_"))
    }

    func testPublishMic() async throws {
        XCTAssert(room.connectionState == .connected)

        try await room.localParticipant.setMicrophone(enabled: true)
        sleep(5)

        let stats = room.localParticipant.localAudioTracks.first?.track?.statistics
        print("Stats: \(String(describing: stats))")
    }
}
#endif
