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

// MARK: - Data Track Cryptor

// Internal cryptor bridging the UniFFI data track providers to E2EEManager. The public
// E2EEManager can't adopt an internally-imported protocol directly, so this internal type carries
// both conformances. It adds no key handling of its own — encryption rides E2EEManager's existing
// AES-GCM data path (LKRTCDataPacketCryptor over the shared BaseKeyProvider), the same path as
// legacy data channel payloads.
final class DataTrackCryptor: EncryptionProvider, DecryptionProvider, @unchecked Sendable {
    // Resolved per call rather than captured: `Room.e2eeManager` is publicly settable, so a
    // manager assigned after connecting must still be used. Weak — the room owns this indirectly
    // through the data track subsystem.
    private weak var room: Room?

    init(room: Room) {
        self.room = room
    }

    private func requireManager() throws -> E2EEManager {
        guard let e2eeManager = room?.e2eeManager else {
            throw LiveKitError(.invalidState, message: "Room has no E2EE manager")
        }
        return e2eeManager
    }

    func encrypt(payload: Data) throws -> EncryptedPayload {
        do {
            let packet = try requireManager().encrypt(data: payload)
            return EncryptedPayload(
                payload: packet.data,
                iv: packet.iv,
                keyIndex: UInt8(truncatingIfNeeded: packet.keyIndex),
            )
        } catch {
            throw EncryptionError.Failed(message: String(describing: error))
        }
    }

    func decrypt(payload: EncryptedPayload, senderIdentity: String) throws -> Data {
        let packet = LKRTCEncryptedPacket(
            data: payload.payload,
            iv: payload.iv,
            keyIndex: UInt32(payload.keyIndex),
        )
        do {
            return try requireManager().handle(encryptedData: packet, participantIdentity: senderIdentity)
        } catch {
            throw DecryptionError.Failed(message: String(describing: error))
        }
    }
}
