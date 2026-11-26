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
    init(_ core: FfiParticipant) {
        identity = core.identity()
        sid = core.sid()
        isLocal = core.isLocal()
        name = core.name()
        state = core.state()
        kind = core.kind()
        kindDetails = core.kindDetails()
        metadata = core.metadata()
        attributes = core.attributes()
        isSpeaking = core.isSpeaking()
        audioLevel = core.audioLevel()
        connectionQuality = core.connectionQuality()
        joinedAt = core.joinedAt()
        permission = core.permission().map(NativeParticipantPermission.init)
        isEncrypted = core.isEncrypted()
        disconnectReason = core.disconnectReason()
        clientProtocol = core.clientProtocol()
        capabilities = core.capabilities()
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
        let core = entry.publication
        sid = core.sid()
        participantIdentity = entry.participant.identity()
        name = core.name()
        kind = core.kind()
        source = core.source()
        isMuted = core.isMuted()
        simulcasted = core.simulcasted()
        width = core.dimensions().width()
        height = core.dimensions().height()
        mimeType = core.mimeType()
        encryptionType = core.encryptionType()
        remote = core.remote().map {
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
    init(_ core: FfiRoomState) {
        dataTracks = core.dataTracks.map { NativeDataTrackPublication(info: $0.info(), publisherIdentity: $0.publisherIdentity()) }
        revision = core.revision
        connection = core.connection
        disconnectReason = core.disconnectReason
        room = core.room
        localParticipant = core.localParticipant.map(NativeParticipant.init)
        remoteParticipants = core.remoteParticipants.map(NativeParticipant.init)
        publications = core.publications.map(NativeTrackPublication.init)
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
    init(_ core: LiveKitFFI.ParticipantPermission) {
        canSubscribe = core.canSubscribe
        canPublish = core.canPublish
        canPublishData = core.canPublishData
        canPublishSources = core.canPublishSources.compactMap {
            switch $0 {
            case 0: .unknown
            case 1: .camera
            case 2: .microphone
            case 3: .screenshare
            case 4: .screenshareAudio
            default: nil
            }
        }
        hidden = core.hidden
        canUpdateMetadata = core.canUpdateMetadata
        canSubscribeMetrics = core.canSubscribeMetrics
        canManageAgentSession = core.canManageAgentSession
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
