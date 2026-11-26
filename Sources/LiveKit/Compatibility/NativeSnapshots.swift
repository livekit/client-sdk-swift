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

// Value projections belong to the removable v2 compatibility layer.
struct NativeParticipant: Equatable, Sendable {
    var identity: String
    var sid: String
    var isLocal: Bool
    var name: String
    var state: NativeParticipantState
    var kind: NativeParticipantKind
    var kindDetails: [NativeParticipantKindDetail]
    var metadata: String
    var attributes: [String: String]
    var isSpeaking: Bool
    var audioLevel: Float
    var connectionQuality: NativeConnectionQuality
    var joinedAt: Int64
    var permission: NativeParticipantPermission?
    var isEncrypted: Bool
    var disconnectReason: NativeDisconnectReason
    var clientProtocol: Int32
    var capabilities: [LiveKitFFI.ClientCapability]?
}

extension NativeParticipant {
    init(_ ffi: FfiParticipant) {
        identity = ffi.identity()
        sid = ffi.sid()
        isLocal = ffi.isLocal()
        name = ffi.name()
        state = ffi.state()
        kind = ffi.kind()
        kindDetails = ffi.kindDetails()
        metadata = ffi.metadata()
        attributes = ffi.attributes()
        isSpeaking = ffi.isSpeaking()
        audioLevel = ffi.audioLevel()
        connectionQuality = ffi.connectionQuality()
        joinedAt = ffi.joinedAt()
        permission = ffi.permission().map(NativeParticipantPermission.init)
        isEncrypted = ffi.isEncrypted()
        disconnectReason = ffi.disconnectReason()
        clientProtocol = ffi.clientProtocol()
        capabilities = ffi.capabilities()
    }
}

struct NativeTrackPublication: Equatable, Sendable {
    var sid: String
    var participantIdentity: String
    var name: String
    var kind: NativeTrackKind
    var source: NativeTrackSource
    var isMuted: Bool
    var simulcasted: Bool
    var width: UInt32
    var height: UInt32
    var mimeType: String
    var encryptionType: NativeEncryptionType
    var remote: NativeRemotePublicationState?
}

extension NativeTrackPublication {
    init(_ entry: FfiPublication) {
        let ffi = entry.publication
        sid = ffi.sid()
        participantIdentity = entry.participant.identity()
        name = ffi.name()
        kind = ffi.kind()
        source = ffi.source()
        isMuted = ffi.isMuted()
        simulcasted = ffi.simulcasted()
        width = ffi.dimensions().width()
        height = ffi.dimensions().height()
        mimeType = ffi.mimeType()
        encryptionType = ffi.encryptionType()
        remote = ffi.remote().map {
            NativeRemotePublicationState(subscriptionStatus: $0.subscriptionStatus(), permissionStatus: $0.permissionStatus(), isEnabled: $0.isEnabled(), streamState: $0.mediaTrack()?.streamState())
        }
    }
}

struct NativeRemotePublicationState: Equatable, Sendable {
    var subscriptionStatus: NativeSubscriptionStatus
    var permissionStatus: NativePermissionStatus
    var isEnabled: Bool
    var streamState: NativeStreamState?
}

struct NativeRoomState: Equatable, Sendable {
    var dataTracks: [NativeDataTrackPublication]
    var revision: UInt64
    var connection: NativeConnectionState
    var disconnectReason: NativeDisconnectReason?
    var room: NativeRoomInfo?
    var localParticipant: NativeParticipant?
    var remoteParticipants: [NativeParticipant]
    var publications: [NativeTrackPublication]
}

extension NativeRoomState {
    init(_ ffi: FfiRoomState) {
        dataTracks = ffi.dataTracks.map { NativeDataTrackPublication(info: $0.info(), publisherIdentity: $0.publisherIdentity()) }
        revision = ffi.revision
        connection = ffi.connection
        disconnectReason = ffi.disconnectReason
        room = ffi.room
        localParticipant = ffi.localParticipant.map(NativeParticipant.init)
        remoteParticipants = ffi.remoteParticipants.map(NativeParticipant.init)
        publications = ffi.publications.map(NativeTrackPublication.init)
    }
}

struct NativeParticipantPermission: Equatable, Sendable {
    var canSubscribe: Bool
    var canPublish: Bool
    var canPublishData: Bool
    var canPublishSources: [NativeTrackSource]
    var hidden: Bool
    var canUpdateMetadata: Bool
    var canSubscribeMetrics: Bool
    var canManageAgentSession: Bool
}

extension NativeParticipantPermission {
    init(_ ffi: LiveKitFFI.ParticipantPermission) {
        canSubscribe = ffi.canSubscribe
        canPublish = ffi.canPublish
        canPublishData = ffi.canPublishData
        canPublishSources = ffi.canPublishSources.compactMap {
            switch $0 {
            case 0: .unknown
            case 1: .camera
            case 2: .microphone
            case 3: .screenshare
            case 4: .screenshareAudio
            default: nil
            }
        }
        hidden = ffi.hidden
        canUpdateMetadata = ffi.canUpdateMetadata
        canSubscribeMetrics = ffi.canSubscribeMetrics
        canManageAgentSession = ffi.canManageAgentSession
    }
}

struct NativeDataTrackPublication: Equatable, Sendable {
    var info: LiveKitFFI.DataTrackInfo
    var publisherIdentity: String
}

extension NativeRoomState {
    mutating func updateParticipant(_ participant: NativeParticipant, allowInsert: Bool = false) {
        if participant.isLocal { localParticipant = participant } else {
            guard allowInsert || remoteParticipants.contains(where: { $0.identity == participant.identity }) else { return }
            remoteParticipants.removeAll { $0.identity == participant.identity }
            remoteParticipants.append(participant)
        }
    }
}

extension NativeRoomState {
    mutating func applyParticipantEvent(_ event: NativeRoomEvent) {
        switch event {
        case let .participantConnected(participant):
            updateParticipant(NativeParticipant(participant), allowInsert: true)
        case let .participantActive(participant), let .participantAttributesChanged(participant, _):
            updateParticipant(NativeParticipant(participant))
        case let .participantsUpdated(participants):
            for participant in participants {
                updateParticipant(NativeParticipant(participant))
            }
        case let .participantMetadataChanged(participant, _, metadata):
            var value = NativeParticipant(participant)
            value.metadata = metadata
            updateParticipant(value)
        case let .participantNameChanged(participant, _, name):
            var value = NativeParticipant(participant)
            value.name = name
            updateParticipant(value)
        case let .participantPermissionChanged(participant, permission):
            var value = NativeParticipant(participant)
            value.permission = permission.map(NativeParticipantPermission.init)
            updateParticipant(value)
        case let .participantEncryptionStatusChanged(participant, isEncrypted):
            var value = NativeParticipant(participant)
            value.isEncrypted = isEncrypted
            updateParticipant(value)
        case let .connectionQualityChanged(participant, quality):
            var value = NativeParticipant(participant)
            value.connectionQuality = quality
            updateParticipant(value)
        default: break
        }
    }
}
