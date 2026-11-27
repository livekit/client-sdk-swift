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
        let values = ffi.observeState().state().values
        identity = values.identity
        sid = values.sid
        isLocal = ffi.isLocal()
        name = values.name
        state = values.state
        kind = values.kind
        kindDetails = values.kindDetails
        metadata = values.metadata
        attributes = values.attributes
        isSpeaking = values.speaking
        audioLevel = values.audioLevel
        connectionQuality = values.connectionQuality
        joinedAt = values.joinedAt
        permission = values.permission.map(NativeParticipantPermission.init)
        isEncrypted = values.isEncrypted
        disconnectReason = values.disconnectReason
        clientProtocol = values.clientProtocol
        capabilities = isLocal ? nil : values.capabilities
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
        let snapshot = ffi.observeState().state()
        let values = snapshot.values
        let track = snapshot.track?.observeState().state().values
        sid = values.sid
        participantIdentity = entry.participant.identity()
        name = values.name
        kind = values.kind
        source = values.source
        // Child state has its own revision; this v2 adapter makes no aggregate atomicity claim.
        isMuted = ffi.isRemote() ? values.muted : track?.muted ?? values.muted
        simulcasted = values.simulcasted
        width = values.width
        height = values.height
        mimeType = values.mimeType
        encryptionType = values.encryptionType
        remote = values.desired.map { desired in
            NativeRemotePublicationState(subscriptionStatus: !desired ? .unsubscribed : snapshot.track == nil ? .desired : .subscribed,
                                         permissionStatus: values.allowed == true ? .allowed : .notAllowed,
                                         // Native-owned values stay Rust-mediated live queries.
                                         isEnabled: snapshot.track?.isEnabled() ?? false,
                                         streamState: track?.streamState)
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
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dataTracks == rhs.dataTracks && lhs.connection == rhs.connection
            && lhs.disconnectReason == rhs.disconnectReason && lhs.room == rhs.room
            && lhs.localParticipant == rhs.localParticipant && lhs.remoteParticipants == rhs.remoteParticipants
            && lhs.publications == rhs.publications
    }
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
