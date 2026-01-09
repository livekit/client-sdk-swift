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

internal import LiveKitWebRTC

// MARK: - EncryptedPacket

extension Livekit_EncryptedPacket {
    init(rtcPacket: LKRTCEncryptedPacket) {
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

// MARK: - EncryptedPacketPayload

extension Livekit_EncryptedPacketPayload {
    init?(dataPacket: Livekit_DataPacket) {
        switch dataPacket.value {
        case let .user(user):
            self.user = user
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
        default:
            return nil
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

// MARK: - DataPacket

extension Livekit_DataPacket {
    // Skip the default value returned from protobufs
    var encryptedPacketOrNil: Livekit_EncryptedPacket? {
        switch value {
        case .encryptedPacket: encryptedPacket
        default: nil
        }
    }
}
