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

@testable import LiveKit

// Pre-built protobuf fixtures for unit testing SignalClient and Room delegate handling.
// swiftlint:disable:next type_body_length
public enum TestData {
    // MARK: - Participant Info

    public static func participantInfo(
        sid: String = "PA_test123",
        identity: String = "test-user",
        name: String = "Test User",
        state: Livekit_ParticipantInfo.State? = nil,
        metadata: String = "",
        attributes: [String: String] = [:],
        kind: Livekit_ParticipantInfo.Kind? = nil,
        joinedAt: Int64 = 1_700_000_000,
        tracks: [Livekit_TrackInfo] = [],
        canPublish: Bool = true,
        canSubscribe: Bool = true,
        canPublishData: Bool = true
    ) -> Livekit_ParticipantInfo {
        Livekit_ParticipantInfo.with {
            $0.sid = sid
            $0.identity = identity
            $0.name = name
            $0.state = state ?? .active
            $0.metadata = metadata
            $0.attributes = attributes
            $0.kind = kind ?? .standard
            $0.joinedAt = joinedAt
            $0.tracks = tracks
            $0.permission = Livekit_ParticipantPermission.with {
                $0.canPublish = canPublish
                $0.canSubscribe = canSubscribe
                $0.canPublishData = canPublishData
            }
        }
    }

    // MARK: - Room Info

    public static func roomInfo(
        sid: String = "RM_test456",
        name: String = "test-room",
        metadata: String = "",
        activeRecording: Bool = false,
        maxParticipants: UInt32 = 100,
        numParticipants: UInt32 = 2,
        numPublishers: UInt32 = 1,
        creationTime: Int64 = 1_700_000_000
    ) -> Livekit_Room {
        Livekit_Room.with {
            $0.sid = sid
            $0.name = name
            $0.metadata = metadata
            $0.activeRecording = activeRecording
            $0.maxParticipants = maxParticipants
            $0.numParticipants = numParticipants
            $0.numPublishers = numPublishers
            $0.creationTime = creationTime
        }
    }

    // MARK: - Server Info

    public static func serverInfo(
        version: String = "1.7.0",
        region: String = "us-east-1",
        nodeID: String = "node-abc123"
    ) -> Livekit_ServerInfo {
        Livekit_ServerInfo.with {
            $0.version = version
            $0.region = region
            $0.nodeID = nodeID
        }
    }

    // MARK: - Join Response

    public static func joinResponse(
        room: Livekit_Room? = nil,
        participant: Livekit_ParticipantInfo? = nil,
        otherParticipants: [Livekit_ParticipantInfo] = [],
        serverInfo: Livekit_ServerInfo? = nil,
        pingInterval: Int32 = 10,
        pingTimeout: Int32 = 20
    ) -> Livekit_JoinResponse {
        Livekit_JoinResponse.with {
            $0.room = room ?? roomInfo()
            $0.participant = participant ?? participantInfo(sid: "PA_local", identity: "local-user", name: "Local User")
            $0.otherParticipants = otherParticipants
            $0.serverInfo = serverInfo ?? self.serverInfo()
            $0.pingInterval = pingInterval
            $0.pingTimeout = pingTimeout
        }
    }

    // MARK: - Connect Response

    public static func connectResponseJoin(
        room: Livekit_Room? = nil,
        participant: Livekit_ParticipantInfo? = nil,
        otherParticipants: [Livekit_ParticipantInfo] = [],
        serverInfo: Livekit_ServerInfo? = nil
    ) -> SignalClient.ConnectResponse {
        .join(joinResponse(
            room: room,
            participant: participant,
            otherParticipants: otherParticipants,
            serverInfo: serverInfo
        ))
    }

    // MARK: - Speaker Info

    public static func speakerInfo(
        sid: String,
        level: Float = 0.8,
        active: Bool = true
    ) -> Livekit_SpeakerInfo {
        Livekit_SpeakerInfo.with {
            $0.sid = sid
            $0.level = level
            $0.active = active
        }
    }

    // MARK: - Connection Quality

    public static func connectionQualityInfo(
        participantSid: String,
        quality: Livekit_ConnectionQuality? = nil
    ) -> Livekit_ConnectionQualityInfo {
        Livekit_ConnectionQualityInfo.with {
            $0.participantSid = participantSid
            $0.quality = quality ?? .good
        }
    }

    // MARK: - Track Info

    public static func trackInfo(
        sid: String = "TR_test789",
        name: String = "microphone",
        type: Livekit_TrackType? = nil,
        source: Livekit_TrackSource? = nil,
        muted: Bool = false
    ) -> Livekit_TrackInfo {
        Livekit_TrackInfo.with {
            $0.sid = sid
            $0.name = name
            $0.type = type ?? .audio
            $0.source = source ?? .microphone
            $0.muted = muted
        }
    }

    // MARK: - User Packet

    public static func userPacket(
        participantIdentity: String = "remote-user",
        payload: Data = Data("hello".utf8),
        topic: String = "chat"
    ) -> Livekit_UserPacket {
        Livekit_UserPacket.with {
            $0.participantIdentity = participantIdentity
            $0.payload = payload
            $0.topic = topic
        }
    }

    // MARK: - Transcription

    public static func transcriptionSegment(
        id: String = "seg-1",
        text: String = "Hello world",
        language: String = "en",
        startTime: UInt64 = 0,
        endTime: UInt64 = 1000,
        isFinal: Bool = false
    ) -> Livekit_TranscriptionSegment {
        Livekit_TranscriptionSegment.with {
            $0.id = id
            $0.text = text
            $0.language = language
            $0.startTime = startTime
            $0.endTime = endTime
            $0.final = isFinal
        }
    }

    public static func transcription(
        participantIdentity: String = "remote-user",
        trackID: String = "TR_audio1",
        segments: [Livekit_TranscriptionSegment] = []
    ) -> Livekit_Transcription {
        Livekit_Transcription.with {
            $0.transcribedParticipantIdentity = participantIdentity
            $0.trackID = trackID
            $0.segments = segments
        }
    }

    // MARK: - Room State Helpers

    /// Creates a Room.State for state machine testing.
    public static func roomState(
        connectionState: ConnectionState = .disconnected,
        isReconnectingWithMode: ReconnectMode? = nil,
        disconnectError: LiveKitError? = nil
    ) -> Room.State {
        var state = Room.State(connectOptions: ConnectOptions(), roomOptions: RoomOptions())
        state.connectionState = connectionState
        state.isReconnectingWithMode = isReconnectingWithMode
        state.disconnectError = disconnectError
        return state
    }

    // MARK: - Subscription Permission Update

    public static func subscriptionPermissionUpdate(
        participantSid: String = "PA_r1",
        trackSid: String = "TR_v1",
        allowed: Bool = true
    ) -> Livekit_SubscriptionPermissionUpdate {
        Livekit_SubscriptionPermissionUpdate.with {
            $0.participantSid = participantSid
            $0.trackSid = trackSid
            $0.allowed = allowed
        }
    }

    // MARK: - Stream State Info

    public static func streamStateInfo(
        participantSid: String = "PA_r1",
        trackSid: String = "TR_v1",
        state: Livekit_StreamState? = nil
    ) -> Livekit_StreamStateInfo {
        Livekit_StreamStateInfo.with {
            $0.participantSid = participantSid
            $0.trackSid = trackSid
            $0.state = state ?? .active
        }
    }

    // MARK: - Room Moved Response

    public static func roomMovedResponse(
        room: Livekit_Room? = nil,
        token: String = "new-token",
        participant: Livekit_ParticipantInfo? = nil,
        otherParticipants: [Livekit_ParticipantInfo] = []
    ) -> Livekit_RoomMovedResponse {
        Livekit_RoomMovedResponse.with {
            if let room { $0.room = room }
            $0.token = token
            if let participant { $0.participant = participant }
            $0.otherParticipants = otherParticipants
        }
    }

    // MARK: - Signal Response Builders

    /// Build a Livekit_SignalResponse wrapping a join response.
    public static func signalResponse(join: Livekit_JoinResponse) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with { $0.join = join }
    }

    /// Build a Livekit_SignalResponse wrapping a room update.
    public static func signalResponse(roomUpdate: Livekit_Room) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.roomUpdate = Livekit_RoomUpdate.with { $0.room = roomUpdate }
        }
    }

    /// Build a Livekit_SignalResponse wrapping participant updates.
    public static func signalResponse(participantUpdate participants: [Livekit_ParticipantInfo]) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.update = Livekit_ParticipantUpdate.with { $0.participants = participants }
        }
    }

    /// Build a Livekit_SignalResponse wrapping speaker updates.
    public static func signalResponse(speakersChanged speakers: [Livekit_SpeakerInfo]) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.speakersChanged = Livekit_SpeakersChanged.with { $0.speakers = speakers }
        }
    }

    /// Build a Livekit_SignalResponse wrapping connection quality updates.
    public static func signalResponse(connectionQuality updates: [Livekit_ConnectionQualityInfo]) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.connectionQuality = Livekit_ConnectionQualityUpdate.with { $0.updates = updates }
        }
    }

    /// Build a Livekit_SignalResponse wrapping a leave request.
    public static func signalResponse(
        leave action: Livekit_LeaveRequest.Action,
        reason: Livekit_DisconnectReason? = nil
    ) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.leave = Livekit_LeaveRequest.with {
                $0.action = action
                $0.reason = reason ?? .clientInitiated
            }
        }
    }

    /// Build a Livekit_SignalResponse wrapping a token refresh.
    public static func signalResponse(refreshToken token: String) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with { $0.refreshToken = token }
    }

    /// Build a Livekit_SignalResponse wrapping a mute update.
    public static func signalResponse(mute trackSid: String, muted: Bool) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.mute = Livekit_MuteTrackRequest.with {
                $0.sid = trackSid
                $0.muted = muted
            }
        }
    }

    /// Build a Livekit_SignalResponse wrapping stream state updates.
    public static func signalResponse(streamStates: [Livekit_StreamStateInfo]) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.streamStateUpdate = Livekit_StreamStateUpdate.with { $0.streamStates = streamStates }
        }
    }

    /// Build a Livekit_SignalResponse wrapping a subscription permission update.
    public static func signalResponse(subscriptionPermission: Livekit_SubscriptionPermissionUpdate) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with { $0.subscriptionPermissionUpdate = subscriptionPermission }
    }

    /// Build a Livekit_SignalResponse wrapping a track published response.
    public static func signalResponse(trackPublished cid: String, track: Livekit_TrackInfo) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.trackPublished = Livekit_TrackPublishedResponse.with {
                $0.cid = cid
                $0.track = track
            }
        }
    }

    /// Build a Livekit_SignalResponse wrapping a track unpublished response.
    public static func signalResponse(trackUnpublished trackSid: String) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.trackUnpublished = Livekit_TrackUnpublishedResponse.with {
                $0.trackSid = trackSid
            }
        }
    }

    /// Build a Livekit_SignalResponse wrapping a room moved response.
    public static func signalResponse(roomMoved: Livekit_RoomMovedResponse) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with { $0.roomMoved = roomMoved }
    }

    /// Build a Livekit_SignalResponse wrapping a pong.
    public static func signalResponse(pong timestamp: Int64) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with { $0.pong = timestamp }
    }

    /// Build a Livekit_SignalResponse wrapping a track subscribed event.
    public static func signalResponse(trackSubscribed trackSid: String) -> Livekit_SignalResponse {
        Livekit_SignalResponse.with {
            $0.trackSubscribed = Livekit_TrackSubscribed.with { $0.trackSid = trackSid }
        }
    }
}
