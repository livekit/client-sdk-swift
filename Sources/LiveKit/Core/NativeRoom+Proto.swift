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

internal import LiveKitFFI
import Foundation
#if !COCOAPODS && !LK_XCFRAMEWORK
import LiveKitNanopb
#endif

// Convert native snapshots for the existing entity update path.
extension NativeRoomInfo {
    func toPBType() -> Livekit_Room {
        .with {
            if let sid { $0.sid = sid }
            $0.name = name
            $0.metadata = metadata
            $0.numParticipants = numParticipants
            $0.numPublishers = numPublishers
            $0.maxParticipants = maxParticipants
            $0.activeRecording = activeRecording
            $0.emptyTimeout = emptyTimeout
            $0.departureTimeout = departureTimeout
            $0.creationTimeMs = creationTime
        }
    }
}

extension NativeParticipant {
    func toPBType(publications: [NativeTrackPublication]) -> Livekit_ParticipantInfo {
        .with {
            $0.identity = identity
            $0.sid = sid
            $0.name = name
            $0.metadata = metadata
            $0.attributes = attributes
            $0.joinedAtMs = joinedAt
            $0.state = state.toPBType()
            $0.kind = kind.toPBType()
            $0.kindDetails = kindDetails.map { $0.toPBType() }
            $0.clientProtocol = clientProtocol
            $0.capabilities = (capabilities ?? []).map {
                switch $0 {
                case .unused: .capUnused
                case .packetTrailer: .capPacketTrailer
                case .compressionDeflateRaw: .capCompressionDeflateRaw
                }
            }
            if let permission { $0.permission = permission.toPBType() }
            $0.tracks = publications.filter { $0.participantIdentity == identity }.map { $0.toPBType() }
        }
    }
}

extension NativeParticipantPermission {
    func toPBType() -> Livekit_ParticipantPermission {
        .with {
            $0.canSubscribe = canSubscribe
            $0.canPublish = canPublish
            $0.canPublishData = canPublishData
            $0.canPublishSources = canPublishSources.map { $0.toPBType() }
            $0.hidden = hidden
            $0.canUpdateMetadata = canUpdateMetadata
            $0.canSubscribeMetrics = canSubscribeMetrics
            $0.canManageAgentSession = canManageAgentSession
        }
    }
}

extension NativeTrackPublication {
    func toPBType() -> Livekit_TrackInfo {
        .with {
            $0.sid = sid
            $0.name = name
            $0.type = kind == .audio ? .audio : .video
            $0.source = source.toPBType()
            $0.muted = isMuted
            $0.simulcast = simulcasted
            $0.width = width
            $0.height = height
            $0.mimeType = mimeType
            $0.encryption = encryptionType.toPBType()
        }
    }
}

extension NativeParticipantState {
    func toPBType() -> Livekit_ParticipantInfo_State {
        switch self {
        case .joining: .joining
        case .joined: .joined
        case .active: .active
        case .disconnected: .disconnected
        }
    }
}

extension NativeParticipantKind {
    func toPBType() -> Livekit_ParticipantInfo_Kind {
        switch self {
        case .standard: .standard
        case .ingress: .ingress
        case .egress: .egress
        case .sip: .sip
        case .agent: .agent
        case .connector: .connector
        case .bridge: .bridge
        }
    }
}

extension NativeParticipantKindDetail {
    func toPBType() -> Livekit_ParticipantInfo_KindDetail {
        switch self {
        case .cloudAgent: .cloudAgent
        case .forwarded: .forwarded
        case .connectorWhatsapp: .connectorWhatsapp
        case .connectorTwilio: .connectorTwilio
        case .bridgeRtsp: .bridgeRtsp
        case .simulation: .simulation
        }
    }
}

extension NativeTrackSource {
    func toPBType() -> Livekit_TrackSource {
        switch self {
        case .unknown: .unknown
        case .camera: .camera
        case .microphone: .microphone
        case .screenshare: .screenShare
        case .screenshareAudio: .screenShareAudio
        }
    }
}

extension NativeEncryptionType {
    func toPBType() -> Livekit_Encryption_TypeEnum {
        switch self {
        case .none: .none
        case .gcm: .gcm
        case .custom: .custom
        }
    }
}
