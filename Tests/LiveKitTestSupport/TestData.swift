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

/// Pre-built protobuf fixtures for unit testing SignalClient and Room delegate handling.
public enum TestData {
    // MARK: - Participant Info

    public static func participantInfo(
        sid: String = "PA_test123",
        identity: String = "test-user",
        name: String = "Test User",
        state: Livekit_ParticipantInfo.State = .active,
        metadata: String = "",
        attributes: [String: String] = [:],
        kind: Livekit_ParticipantInfo.Kind = .standard,
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
            $0.state = state
            $0.metadata = metadata
            $0.attributes = attributes
            $0.kind = kind
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
        quality: Livekit_ConnectionQuality = .good
    ) -> Livekit_ConnectionQualityInfo {
        Livekit_ConnectionQualityInfo.with {
            $0.participantSid = participantSid
            $0.quality = quality
        }
    }

    // MARK: - Track Info

    public static func trackInfo(
        sid: String = "TR_test789",
        name: String = "microphone",
        type: Livekit_TrackType = .audio,
        source: Livekit_TrackSource = .microphone,
        muted: Bool = false
    ) -> Livekit_TrackInfo {
        Livekit_TrackInfo.with {
            $0.sid = sid
            $0.name = name
            $0.type = type
            $0.source = source
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
}
