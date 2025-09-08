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

import Foundation

internal import LiveKitWebRTC

// MARK: - EncryptedPacket Extensions

extension Livekit_EncryptedPacket {
    init(from rtcPacket: LKRTCEncryptedPacket) {
        encryptionType = .gcm
        iv = rtcPacket.iv
        keyIndex = rtcPacket.keyIndex
        encryptedValue = rtcPacket.data
    }

    func toRTCEncryptedPacket() -> LKRTCEncryptedPacket {
        LKRTCEncryptedPacket(
            data: encryptedValue,
            iv: iv,
            keyIndex: keyIndex
        )
    }
}

// MARK: - EncryptedPacketPayload Extensions

extension Livekit_EncryptedPacketPayload {
    init(from dataPacket: Livekit_DataPacket) throws {
        switch dataPacket.value {
        case let .user(userPacket):
            user = userPacket
        case let .chatMessage(chatMessage):
            self.chatMessage = chatMessage
        case let .rpcRequest(rpcRequest):
            self.rpcRequest = rpcRequest
        case let .rpcAck(rpcAck):
            self.rpcAck = rpcAck
        case let .rpcResponse(rpcResponse):
            self.rpcResponse = rpcResponse
        case let .streamHeader(streamHeader):
            self.streamHeader = streamHeader
        case let .streamChunk(streamChunk):
            self.streamChunk = streamChunk
        case let .streamTrailer(streamTrailer):
            self.streamTrailer = streamTrailer
        case .encryptedPacket:
            // Already encrypted, this shouldn't happen
            throw LiveKitError(.encryptionFailed, message: "Attempting to encrypt an already encrypted packet")
        case .sipDtmf, .transcription, .metrics, .speaker, .none:
            // These types are not encrypted
            throw LiveKitError(.encryptionFailed, message: "Unsupported packet type for encryption")
        }
    }

    func applyTo(_ dataPacket: inout Livekit_DataPacket) {
        switch value {
        case let .user(userPacket):
            dataPacket.user = userPacket
        case let .chatMessage(chatMessage):
            dataPacket.chatMessage = chatMessage
        case let .rpcRequest(rpcRequest):
            dataPacket.rpcRequest = rpcRequest
        case let .rpcAck(rpcAck):
            dataPacket.rpcAck = rpcAck
        case let .rpcResponse(rpcResponse):
            dataPacket.rpcResponse = rpcResponse
        case let .streamHeader(streamHeader):
            dataPacket.streamHeader = streamHeader
        case let .streamChunk(streamChunk):
            dataPacket.streamChunk = streamChunk
        case let .streamTrailer(streamTrailer):
            dataPacket.streamTrailer = streamTrailer
        case .none:
            break
        }
    }
}

// MARK: - DataPacket E2EE Helper Extensions

extension Livekit_DataPacket {
    var hasEncryptablePayload: Bool {
        switch value {
        case .user, .chatMessage, .rpcRequest, .rpcAck, .rpcResponse,
             .streamHeader, .streamChunk, .streamTrailer:
            true
        case .encryptedPacket, .sipDtmf, .transcription, .metrics, .speaker, .none:
            false
        }
    }

    var hasDecryptablePayload: Bool {
        switch value {
        case .encryptedPacket: true
        default: false
        }
    }

    func encrypted(using encryptedPacket: Livekit_EncryptedPacket) -> Livekit_DataPacket {
        var encrypted = Livekit_DataPacket()

        // Copy metadata fields
        encrypted.participantIdentity = participantIdentity
        encrypted.participantSid = participantSid
        encrypted.destinationIdentities = destinationIdentities
        encrypted.sequence = sequence

        // Set the encrypted payload
        encrypted.encryptedPacket = encryptedPacket

        return encrypted
    }

    func decrypted(with payload: Livekit_EncryptedPacketPayload) -> Livekit_DataPacket {
        var decrypted = Livekit_DataPacket()

        // Copy metadata fields
        decrypted.participantIdentity = participantIdentity
        decrypted.participantSid = participantSid
        decrypted.destinationIdentities = destinationIdentities
        decrypted.sequence = sequence

        // Apply the decrypted payload
        payload.applyTo(&decrypted)

        return decrypted
    }
}
