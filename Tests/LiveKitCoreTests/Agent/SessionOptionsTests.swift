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

class SessionOptionsTests: LKTestCase, @unchecked Sendable {
    // MARK: - EncryptionOptions.sharedKey

    func testSharedKeyFactoryDefaults() {
        let options = EncryptionOptions.sharedKey("my-secret")

        XCTAssertEqual(options.encryptionType, .gcm)
        XCTAssertTrue(options.keyProvider.options.sharedKey)
    }

    func testSharedKeyFactoryRespectsEncryptionType() {
        let options = EncryptionOptions.sharedKey("my-secret", encryptionType: .custom)

        XCTAssertEqual(options.encryptionType, .custom)
        XCTAssertTrue(options.keyProvider.options.sharedKey)
    }

    // MARK: - SessionOptions(encryption:)

    func testEncryptionInitPlumbsOptionsThroughToRoom() {
        let encryption = EncryptionOptions.sharedKey("my-secret")
        let options = SessionOptions(encryption: encryption)

        // The underlying Room carries the encryption options in its RoomOptions.
        let plumbed = options.room._state.roomOptions.encryptionOptions
        XCTAssertNotNil(plumbed)
        XCTAssertTrue(plumbed === encryption)
    }

    func testEncryptionInitPreservesOtherDefaults() {
        let options = SessionOptions(encryption: .sharedKey("k"))

        XCTAssertTrue(options.preConnectAudio)
        XCTAssertEqual(options.agentConnectTimeout, 20)
    }

    func testEncryptionInitForwardsOtherOptions() {
        let options = SessionOptions(
            encryption: .sharedKey("k"),
            preConnectAudio: false,
            agentConnectTimeout: 5
        )

        XCTAssertFalse(options.preConnectAudio)
        XCTAssertEqual(options.agentConnectTimeout, 5)
    }

    // MARK: - SessionOptions(room:) escape hatch

    func testRoomInitPreservesProvidedRoom() {
        let provided = Room()
        let options = SessionOptions(room: provided)

        XCTAssertTrue(options.room === provided)
    }
}
