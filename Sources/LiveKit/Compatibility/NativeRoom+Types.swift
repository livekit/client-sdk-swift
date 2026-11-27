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

// Native records feed the existing public types directly.
extension NativeParticipantState {
    var lkType: ParticipantState {
        switch self {
        case .joining: .joining
        case .joined: .joined
        case .active: .active
        case .disconnected: .disconnected
        @unknown default: .unknown
        }
    }
}

extension NativeParticipantKind {
    var lkType: Participant.Kind {
        switch self {
        case .standard: .standard
        case .ingress: .ingress
        case .egress: .egress
        case .sip: .sip
        case .agent: .agent
        default: .unknown
        }
    }
}

extension NativeTrackSource {
    var lkType: Track.Source {
        switch self {
        case .camera: .camera
        case .microphone: .microphone
        case .screenshare: .screenShareVideo
        case .screenshareAudio: .screenShareAudio
        default: .unknown
        }
    }
}

extension NativeEncryptionType {
    var lkType: EncryptionType {
        switch self {
        case .none: .none
        case .gcm: .gcm
        default: .custom
        }
    }
}

extension NativeParticipantPermission {
    var lkType: ParticipantPermissions {
        ParticipantPermissions(canSubscribe: canSubscribe,
                               canPublish: canPublish,
                               canPublishData: canPublishData,
                               canPublishSources: Set(canPublishSources.map(\.lkType)),
                               hidden: hidden,
                               canUpdateMetadata: canUpdateMetadata,
                               canSubscribeMetrics: canSubscribeMetrics,
                               canManageAgentSession: canManageAgentSession)
    }
}

extension NativeDisconnectReason {
    var lkErrorType: LiveKitErrorType {
        switch self {
        case .clientInitiated: .cancelled
        case .duplicateIdentity: .duplicateIdentity
        case .serverShutdown: .serverShutdown
        case .participantRemoved: .participantRemoved
        case .roomDeleted: .roomDeleted
        case .stateMismatch: .stateMismatch
        case .joinFailure: .joinFailure
        default: .unknown
        }
    }
}

// v2 compatibility names stay outside the generated FFI boundary.
typealias NativeRoomInfo = LiveKitFFI.RoomInfo
typealias NativeIceServer = LiveKitFFI.IceServer

// The v2 convenience initializer deliberately keeps its historical simulcast default.
extension LiveKitFFI.TrackPublishOptions {
    init(source: NativeTrackSource, dtx: Bool = true, red: Bool = true, simulcast: Bool = false, stream: String = "") {
        self = defaultTrackPublishOptions()
        self.source = source
        self.dtx = dtx
        self.red = red
        self.simulcast = simulcast
        self.stream = stream
    }
}

typealias NativeEncryptionState = LiveKitFFI.EncryptionState
typealias NativeEncryptionType = LiveKitFFI.EncryptionType
typealias NativeConnectionQuality = LiveKitFFI.ConnectionQuality
typealias NativeDisconnectReason = LiveKitFFI.DisconnectReason
typealias NativeParticipantKind = LiveKitFFI.ParticipantKind
typealias NativeParticipantKindDetail = LiveKitFFI.ParticipantKindDetail
typealias NativeParticipantState = LiveKitFFI.ParticipantState
typealias NativePermissionStatus = LiveKitFFI.PermissionStatus
typealias NativeSubscriptionStatus = LiveKitFFI.SubscriptionStatus
typealias NativeTrackKind = LiveKitFFI.TrackKind
typealias NativeTrackSource = LiveKitFFI.TrackSource
typealias NativeStreamState = LiveKitFFI.StreamState
typealias NativeDataPacketKind = LiveKitFFI.DataPacketKind
typealias NativeIceTransportPolicy = LiveKitFFI.IceTransportPolicy
typealias NativeContinualGatheringPolicy = LiveKitFFI.ContinualGatheringPolicy
typealias NativeVideoQuality = LiveKitFFI.VideoQuality

typealias NativeTrackPermission = LiveKitFFI.ParticipantTrackPermission

extension NativeRoomDriver {
    static func milliseconds(_ interval: TimeInterval) throws -> UInt64 {
        guard interval.isFinite, interval >= 0, interval * 1000 < Double(UInt64.max) else {
            throw LiveKitError(.invalidParameter, message: "Invalid timeout")
        }
        return UInt64(interval * 1000)
    }

    static func options(_ connect: ConnectOptions, _ room: RoomOptions) throws -> FfiRoomOptions {
        let defaults = ConnectOptions()
        #warning("TODO: Export nondefault connection options from the native session before accepting them here")
        guard connect.reconnectAttempts == defaults.reconnectAttempts,
              connect.reconnectAttemptDelay == defaults.reconnectAttemptDelay,
              connect.reconnectMaxDelay == defaults.reconnectMaxDelay,
              connect.primaryTransportConnectTimeout == defaults.primaryTransportConnectTimeout,
              connect.publisherTransportConnectTimeout == defaults.publisherTransportConnectTimeout,
              connect.iceTransportPolicy != .none,
              !connect.isDscpEnabled, !connect.enableMicrophone,
              connect.protocolVersion == defaults.protocolVersion, connect.clientProtocol == defaults.clientProtocol
        else {
            throw LiveKitError(.invalidParameter, message: "A nondefault connection/media/encryption option is not exported by the native session")
        }
        let payload = room.dataStreamOptions.maxPayloadByteLength
        let encryption: NativeEncryptionOptions?
        if let options = room.encryptionOptions {
            guard options.encryptionType == .gcm else { throw LiveKitError(.invalidParameter, message: "Only native AES-GCM is supported") }
            encryption = try .init(keyProvider: options.keyProvider.nativeProvider())
        } else if let options = room.e2eeOptions {
            guard options.encryptionType == .gcm else { throw LiveKitError(.invalidParameter, message: "Only native AES-GCM is supported") }
            encryption = try .init(keyProvider: options.keyProvider.nativeProvider(), legacyMediaOnly: true)
        } else { encryption = nil }
        _ = try milliseconds(connect.socketConnectTimeoutInterval)
        return try FfiRoomOptions()
            .withAutoSubscribe(value: connect.autoSubscribe)
            .withAdaptiveStream(value: room.adaptiveStream)
            .withDynacast(value: room.dynacast)
            .withSinglePeerConnection(value: room.singlePeerConnection)
            .withConnectTimeout(value: connect.socketConnectTimeoutInterval)
            .withSdk(sdk: "swift", sdkVersion: LiveKitSDK.version, otherSdks: nil)
            .withMaxStreamPayloadBytes(value: payload.map(UInt64.init))
            .withEncryption(value: encryption)
            .withRtcConfig(iceServers: connect.iceServers.map { .init(urls: $0.urls, username: $0.username ?? "", password: $0.credential ?? "") },
                           iceTransportPolicy: connect.iceTransportPolicy == .relay ? .relay : connect.iceTransportPolicy == .noHost ? .noHost : .all,
                           continualGatheringPolicy: .gatherContinually, enableSctpSnap: false)
    }
}

extension ParticipantTrackPermission {
    func toNative(identity: String) throws -> NativeTrackPermission {
        let sids = allTracksAllowed ? [] : allowedTrackSids
        guard sids.allSatisfy({ $0.hasPrefix("TR_") }) else {
            throw LiveKitError(.invalidParameter, message: "Invalid track SID")
        }
        return NativeTrackPermission(participantIdentity: identity, allowAll: allTracksAllowed, allowedTrackSids: sids)
    }
}

extension NativeRoomDriver {
    static func initialState(_ native: FfiRoom, connected: FfiRoomState) async throws -> NativeRoomState {
        var states = native.states.makeAsyncIterator()
        guard let initial = try await states.next() else { throw CancellationError() }
        // Keep the ordered cursor's membership baseline. Child values are owned
        // observations, and room values come from the authoritative state stream.
        var snapshot = NativeRoomState(connected)
        if var info = initial.values.room {
            info.metadata = snapshot.room?.metadata ?? info.metadata
            info.activeRecording = snapshot.room?.activeRecording ?? info.activeRecording
            snapshot.room = info
        }
        return snapshot
    }
}
