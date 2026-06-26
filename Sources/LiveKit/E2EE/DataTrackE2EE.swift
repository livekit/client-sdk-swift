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

internal import LiveKitUniFFI
internal import LiveKitWebRTC

// MARK: - Data Track E2EE Providers

// Internal adapters bridging the UniFFI data track providers to `E2EEManager`. The public
// `E2EEManager` can't conform directly — a public type may not adopt a protocol from an
// `internal import`ed module — so these internal wrappers carry the conformance instead. They add
// no key handling of their own: encryption rides E2EEManager's existing AES-GCM data path
// (LKRTCDataPacketCryptor over the shared BaseKeyProvider), the same path as legacy data channel
// payloads.

final class DataTrackEncryptionProvider: EncryptionProvider, @unchecked Sendable {
    private let e2eeManager: E2EEManager

    init(e2eeManager: E2EEManager) {
        self.e2eeManager = e2eeManager
    }

    func encrypt(payload: Data) throws -> EncryptedPayload {
        do {
            let packet = try e2eeManager.encrypt(data: payload)
            return EncryptedPayload(
                payload: packet.data,
                iv: packet.iv,
                keyIndex: UInt8(truncatingIfNeeded: packet.keyIndex),
            )
        } catch {
            throw EncryptionError.Failed(message: String(describing: error))
        }
    }
}

final class DataTrackDecryptionProvider: DecryptionProvider, @unchecked Sendable {
    private let e2eeManager: E2EEManager

    init(e2eeManager: E2EEManager) {
        self.e2eeManager = e2eeManager
    }

    func decrypt(payload: EncryptedPayload, senderIdentity: String) throws -> Data {
        let packet = LKRTCEncryptedPacket(
            data: payload.payload,
            iv: payload.iv,
            keyIndex: UInt32(payload.keyIndex),
        )
        do {
            return try e2eeManager.handle(encryptedData: packet, participantIdentity: senderIdentity)
        } catch {
            throw DecryptionError.Failed(message: String(describing: error))
        }
    }
}
