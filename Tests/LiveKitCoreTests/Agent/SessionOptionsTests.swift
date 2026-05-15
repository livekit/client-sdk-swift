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
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

struct SessionOptionsTests {
    // MARK: - EncryptionOptions.sharedKey

    @Test func sharedKeyFactoryDefaults() {
        let options = EncryptionOptions.sharedKey("my-secret")

        #expect(options.encryptionType == .gcm)
        #expect(options.keyProvider.options.sharedKey)
    }

    @Test func sharedKeyFactoryRespectsEncryptionType() {
        let options = EncryptionOptions.sharedKey("my-secret", encryptionType: .custom)

        #expect(options.encryptionType == .custom)
        #expect(options.keyProvider.options.sharedKey)
    }

    // MARK: - SessionOptions(encryption:)

    @Test func encryptionInitPlumbsOptionsThroughToRoom() {
        let encryption = EncryptionOptions.sharedKey("my-secret")
        let options = SessionOptions(encryption: encryption)

        // The underlying Room carries the encryption options in its RoomOptions.
        let plumbed = options.room._state.roomOptions.encryptionOptions
        #expect(plumbed != nil)
        #expect(plumbed === encryption)
    }

    @Test func encryptionInitPreservesOtherDefaults() {
        let options = SessionOptions(encryption: .sharedKey("k"))

        #expect(options.preConnectAudio)
        #expect(options.agentConnectTimeout == 20)
    }

    @Test func encryptionInitForwardsOtherOptions() {
        let options = SessionOptions(
            encryption: .sharedKey("k"),
            preConnectAudio: false,
            agentConnectTimeout: 5
        )

        #expect(!options.preConnectAudio)
        #expect(options.agentConnectTimeout == 5)
    }

    // MARK: - SessionOptions(room:) escape hatch

    @Test func roomInitPreservesProvidedRoom() {
        let provided = Room()
        let options = SessionOptions(room: provided)

        #expect(options.room === provided)
    }
}
