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
import LiveKit
import Testing

@Suite(.tags(.e2ee))
struct BaseKeyProviderTests {
    @Test
    func defaultKeyRingSizeIsSixteen() {
        #expect(KeyProviderOptions().keyRingSize == 16)
    }

    @Test
    func roundTripAtInRangeIndex() throws {
        let provider = BaseKeyProvider(options: KeyProviderOptions(sharedKey: true, keyRingSize: 16))
        provider.setKey(key: "k", index: 7)
        let exported = try #require(provider.exportKey(index: 7))
        #expect(exported == Data("k".utf8))
    }

    @Test
    func setKeyModuloWrapsOutOfRangePositive() throws {
        let provider = BaseKeyProvider(options: KeyProviderOptions(sharedKey: true, keyRingSize: 16))
        // 21 % 16 == 5: SetKeyFromMaterial wraps before subscripting.
        provider.setKey(key: "wrapped", index: 21)
        let exported = try #require(provider.exportKey(index: 5))
        #expect(exported == Data("wrapped".utf8))
    }

    @Test
    func setKeyNegativeIndexWritesToCurrent() throws {
        let provider = BaseKeyProvider(options: KeyProviderOptions(sharedKey: true, keyRingSize: 16))
        provider.setKey(key: "first", index: 3) // current_key_index_ = 3
        provider.setKey(key: "next", index: -1) // SetKeyFromMaterial leaves current_key_index_ alone for negative input
        let exported = try #require(provider.exportKey(index: 3))
        #expect(exported == Data("next".utf8))
    }

    @Test("keyRingSize=256 with index 254 round-trips")
    func sharedKeyAtMaxSafeIndex() throws {
        let provider = BaseKeyProvider(options: KeyProviderOptions(sharedKey: true, keyRingSize: 256))
        // 254 is the last reachable index: upstream ParticipantKeyHandler clamps the
        // requested 256 to MAX_KEYRING_SIZE = 255, so the vector ends at index 254.
        provider.setKey(key: "test-key", index: 254)
        let exported = try #require(provider.exportKey(index: 254))
        #expect(exported == Data("test-key".utf8))
    }

    @Test(
        "keyRingSize=256 with index 255 round-trips",
        .bug("https://github.com/livekit/client-sdk-swift/issues/1030"),
        .disabled("Crashes the test process via libc++ hardening assertion — see issue #1030"),
    )
    func sharedKeyAtKeyRingBoundary() throws {
        let provider = BaseKeyProvider(options: KeyProviderOptions(sharedKey: true, keyRingSize: 256))
        provider.setKey(key: "test-key", index: 255)
        let exported = try #require(provider.exportKey(index: 255))
        #expect(exported == Data("test-key".utf8))
    }

    @Test(
        .bug("https://github.com/livekit/client-sdk-swift/issues/1030"),
        .disabled("Crashes the test process via libc++ hardening assertion — see issue #1030"),
    )
    func exportKeyOutOfRangeReturnsNoKey() {
        let provider = BaseKeyProvider(options: KeyProviderOptions(sharedKey: true, keyRingSize: 16))
        provider.setKey(key: "k", index: 0)
        // Post-patch the bridge maps an empty std::vector to an empty NSData,
        // mirroring JS where `cryptoKeyRing[oob]` yields `undefined`.
        #expect(provider.exportKey(index: 100)?.isEmpty == true)
    }
}
