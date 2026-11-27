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
    var localParticipant: LiveKitFFI.ParticipantInfo?
    var remoteParticipants: [LiveKitFFI.ParticipantInfo]
    var publications: [NativeTrackPublication]
}

extension NativeRoomState {
    // Revision is the only excluded field; add every future content field here.
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
        localParticipant = ffi.localParticipant.map { $0.observeState().state().values }
        remoteParticipants = ffi.remoteParticipants.map { $0.observeState().state().values }
        publications = ffi.publications.map(NativeTrackPublication.init)
    }
}

struct NativeDataTrackPublication: Equatable, Sendable {
    var info: LiveKitFFI.DataTrackInfo
    var publisherIdentity: String
}

extension NativeRoomState {
    mutating func updateParticipant(_ participant: LiveKitFFI.ParticipantInfo, isLocal: Bool, allowInsert: Bool = false) {
        if isLocal { localParticipant = participant } else {
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
            updateParticipant(participant.observeState().state().values, isLocal: participant.isLocal(), allowInsert: true)
        case let .participantActive(participant), let .participantAttributesChanged(participant, _):
            updateParticipant(participant.observeState().state().values, isLocal: participant.isLocal())
        case let .participantsUpdated(participants):
            for participant in participants {
                updateParticipant(participant.observeState().state().values, isLocal: participant.isLocal())
            }
        case let .participantMetadataChanged(participant, _, metadata):
            var value = participant.observeState().state().values
            value.metadata = metadata
            updateParticipant(value, isLocal: participant.isLocal())
        case let .participantNameChanged(participant, _, name):
            var value = participant.observeState().state().values
            value.name = name
            updateParticipant(value, isLocal: participant.isLocal())
        case let .participantPermissionChanged(participant, permission):
            var value = participant.observeState().state().values
            value.permission = permission
            updateParticipant(value, isLocal: participant.isLocal())
        case let .participantEncryptionStatusChanged(participant, isEncrypted):
            var value = participant.observeState().state().values
            value.isEncrypted = isEncrypted
            updateParticipant(value, isLocal: participant.isLocal())
        case let .connectionQualityChanged(participant, quality):
            var value = participant.observeState().state().values
            value.connectionQuality = quality
            updateParticipant(value, isLocal: participant.isLocal())
        default: break
        }
    }
}
