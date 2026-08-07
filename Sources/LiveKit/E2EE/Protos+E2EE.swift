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
        self = .with {
            $0.encryptionType = .gcm
            $0.iv = rtcPacket.iv
            $0.keyIndex = rtcPacket.keyIndex
            $0.encryptedValue = rtcPacket.data
        }
    }

    func toRTCEncryptedPacket() -> LKRTCEncryptedPacket {
        LKRTCEncryptedPacket(
            data: encryptedValue,
            iv: iv,
            keyIndex: keyIndex,
        )
    }
}

// MARK: - EncryptedPacketPayload

extension Livekit_EncryptedPacketPayload {
    init?(dataPacket: Livekit_DataPacket) {
        switch dataPacket.value {
        case let .user(user):
            self = .with { $0.user = user }
        case let .chatMessage(chatMessage):
            self = .with { $0.chatMessage = chatMessage }
        case let .rpcRequest(rpcRequest):
            self = .with { $0.rpcRequest = rpcRequest }
        case let .rpcAck(rpcAck):
            self = .with { $0.rpcAck = rpcAck }
        case let .rpcResponse(rpcResponse):
            self = .with { $0.rpcResponse = rpcResponse }
        case let .streamHeader(streamHeader):
            self = .with { $0.streamHeader = streamHeader }
        case let .streamChunk(streamChunk):
            self = .with { $0.streamChunk = streamChunk }
        case let .streamTrailer(streamTrailer):
            self = .with { $0.streamTrailer = streamTrailer }
        default:
            return nil
        }
    }

    func applyTo(_ builder: inout Livekit_DataPacket.Builder) {
        switch value {
        case let .user(userPacket):
            builder.user = userPacket
        case let .chatMessage(chatMessage):
            builder.chatMessage = chatMessage
        case let .rpcRequest(rpcRequest):
            builder.rpcRequest = rpcRequest
        case let .rpcAck(rpcAck):
            builder.rpcAck = rpcAck
        case let .rpcResponse(rpcResponse):
            builder.rpcResponse = rpcResponse
        case let .streamHeader(streamHeader):
            builder.streamHeader = streamHeader
        case let .streamChunk(streamChunk):
            builder.streamChunk = streamChunk
        case let .streamTrailer(streamTrailer):
            builder.streamTrailer = streamTrailer
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
