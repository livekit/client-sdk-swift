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

import CryptoKit
import Foundation
@testable import LiveKit
import LiveKitWebRTC
import Testing

/// Decrypts a native data packet with an independent HKDF + AES-GCM implementation,
/// the same derivation the JS SDK uses (`info` = 128 zero bytes, salt = ratchet salt).
@Suite(.tags(.e2ee))
struct KeySizeTests {
    @Test
    func defaultKeySizeIs128() {
        #expect(KeyProviderOptions().keySize == .bits128)
    }

    @Test
    func optionsEqualityIncludesKeySize() {
        let options = KeyProviderOptions(keySize: .bits256)
        let equalOptions = KeyProviderOptions(keySize: .bits256)
        #expect(options != KeyProviderOptions())
        #expect(options == equalOptions)
        #expect(options.hash == equalOptions.hash)
    }

    @available(iOS 14.0, macOS 11.0, macCatalyst 14.0, tvOS 14.0, visionOS 1.0, *)
    @Test(arguments: [(KeySize.bits128, KeySize.bits256), (.bits256, .bits128)])
    func nativeDerivedKeyLength(keySize: KeySize, mismatchedKeySize: KeySize) throws {
        let material = Data("key-size-probe".utf8)
        let options = KeyProviderOptions(sharedKey: true, keyDerivationAlgorithm: .hkdf, keySize: keySize)
        let provider = BaseKeyProvider(options: options)
        provider.setKey(keyData: material, index: 0)

        let cryptor = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: provider.rtcKeyProvider))
        let plaintext = Data("hello".utf8)
        let packet = try #require(cryptor.encrypt("p", keyIndex: 0, data: plaintext))

        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material),
                                         salt: options.ratchetSalt,
                                         info: Data(count: 128),
                                         outputByteCount: keySize.rawValue / 8)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: packet.iv),
                                        ciphertext: packet.data.dropLast(16),
                                        tag: packet.data.suffix(16))
        #expect(try AES.GCM.open(box, using: key) == plaintext)

        let mismatchedKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material),
                                                   salt: options.ratchetSalt,
                                                   info: Data(count: 128),
                                                   outputByteCount: mismatchedKeySize.rawValue / 8)
        #expect(throws: CryptoKitError.self) {
            try AES.GCM.open(box, using: mismatchedKey)
        }
    }
}
