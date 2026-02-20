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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Tests for Participant and RemoteParticipant state management.
class ParticipantStateTests: LKTestCase {
    // MARK: - Helper

    private func makeRoom() -> Room {
        let room = Room()
        room._state.mutate { $0.connectionState = .connected }
        let localInfo = TestData.participantInfo(sid: "PA_local", identity: "local-user")
        room.localParticipant.set(info: localInfo, connectionState: .connected)
        return room
    }

    private func makeRemoteParticipant(
        sid: String = "PA_remote",
        identity: String = "remote-user",
        name: String = "Remote User",
        room: Room? = nil
    ) -> RemoteParticipant {
        let room = room ?? makeRoom()
        let info = TestData.participantInfo(sid: sid, identity: identity, name: name)
        return RemoteParticipant(info: info, room: room, connectionState: .connected)
    }

    // MARK: - RemoteParticipant Init

    func testRemoteParticipantInitSetsBasicProperties() {
        let participant = makeRemoteParticipant(sid: "PA_abc", identity: "alice", name: "Alice")

        XCTAssertEqual(participant.sid?.stringValue, "PA_abc")
        XCTAssertEqual(participant.identity?.stringValue, "alice")
        XCTAssertEqual(participant.name, "Alice")
    }

    func testRemoteParticipantInitSetsState() {
        let room = makeRoom()
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", state: .active)
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertEqual(participant.state, .active)
    }

    func testRemoteParticipantInitSetsKind() {
        let room = makeRoom()
        let info = TestData.participantInfo(sid: "PA_agent", identity: "agent-1", kind: .agent)
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertEqual(participant.kind, .agent)
    }

    // MARK: - set(info:) Updates

    func testSetInfoUpdatesMetadata() {
        let participant = makeRemoteParticipant()

        let updated = TestData.participantInfo(
            sid: "PA_remote",
            identity: "remote-user",
            metadata: "new-metadata"
        )
        participant.set(info: updated, connectionState: .connected)

        XCTAssertEqual(participant.metadata, "new-metadata")
    }

    func testSetInfoUpdatesName() {
        let participant = makeRemoteParticipant()

        let updated = TestData.participantInfo(
            sid: "PA_remote",
            identity: "remote-user",
            name: "Updated Name"
        )
        participant.set(info: updated, connectionState: .connected)

        XCTAssertEqual(participant.name, "Updated Name")
    }

    func testSetInfoUpdatesAttributes() {
        let participant = makeRemoteParticipant()

        let updated = TestData.participantInfo(
            sid: "PA_remote",
            identity: "remote-user",
            attributes: ["role": "speaker", "color": "blue"]
        )
        participant.set(info: updated, connectionState: .connected)

        XCTAssertEqual(participant.attributes["role"], "speaker")
        XCTAssertEqual(participant.attributes["color"], "blue")
    }

    func testSetInfoUpdatesPermissions() {
        let room = makeRoom()
        let info = TestData.participantInfo(
            sid: "PA_remote",
            identity: "remote-user",
            canPublish: false,
            canSubscribe: false,
            canPublishData: false
        )
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertFalse(participant.permissions.canPublish)
        XCTAssertFalse(participant.permissions.canSubscribe)
        XCTAssertFalse(participant.permissions.canPublishData)

        // Update to grant permissions
        let updated = TestData.participantInfo(
            sid: "PA_remote",
            identity: "remote-user",
            canPublish: true,
            canSubscribe: true,
            canPublishData: true
        )
        participant.set(info: updated, connectionState: .connected)

        XCTAssertTrue(participant.permissions.canPublish)
        XCTAssertTrue(participant.permissions.canSubscribe)
        XCTAssertTrue(participant.permissions.canPublishData)
    }

    func testSetInfoUpdatesJoinedAt() {
        let room = makeRoom()
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", joinedAt: 1_700_000_000)
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertNotNil(participant.joinedAt)
        XCTAssertEqual(participant.joinedAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1.0)
    }

    func testSetInfoWithJoinedAtMs() {
        let room = makeRoom()
        var info = TestData.participantInfo(sid: "PA_1", identity: "user-1")
        info.joinedAt = 0
        info.joinedAtMs = 1_700_000_000_500
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertNotNil(participant.joinedAt)
        XCTAssertEqual(participant.joinedAt?.timeIntervalSince1970 ?? 0, 1_700_000_000.5, accuracy: 0.001)
    }

    // MARK: - Track Publications from Info

    func testSetInfoCreatesTrackPublications() {
        let room = makeRoom()
        let track1 = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio, source: .microphone)
        let track2 = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [track1, track2])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertEqual(participant.trackPublications.count, 2)

        let audioSid = Track.Sid(from: "TR_a1")
        let videoSid = Track.Sid(from: "TR_v1")
        XCTAssertNotNil(participant.trackPublications[audioSid])
        XCTAssertNotNil(participant.trackPublications[videoSid])
    }

    func testSetInfoRemovesUnpublishedTracks() {
        let room = makeRoom()
        let track1 = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio)
        let track2 = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [track1, track2])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)
        XCTAssertEqual(participant.trackPublications.count, 2)

        // Update with only one track — the other should be removed
        let updatedInfo = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [track1])
        participant.set(info: updatedInfo, connectionState: .connected)

        // Allow async unpublish
        let expectation = expectation(description: "track unpublish")
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(participant.trackPublications.count, 1)
        let audioSid = Track.Sid(from: "TR_a1")
        XCTAssertNotNil(participant.trackPublications[audioSid])
    }

    func testSetInfoUpdatesExistingTrackPublications() {
        let room = makeRoom()
        let track = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio, muted: false)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [track])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)
        XCTAssertEqual(participant.trackPublications.count, 1)

        // Update with same track but muted
        let mutedTrack = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio, muted: true)
        let updatedInfo = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [mutedTrack])
        participant.set(info: updatedInfo, connectionState: .connected)

        // Should still have 1 publication (updated, not replaced)
        XCTAssertEqual(participant.trackPublications.count, 1)
    }

    // MARK: - Audio Tracks / Video Tracks Convenience

    func testAudioTracksFilter() {
        let room = makeRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio)
        let videoTrack = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [audioTrack, videoTrack])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertEqual(participant.audioTracks.count, 1)
        XCTAssertEqual(participant.videoTracks.count, 1)
    }

    // MARK: - Participant State Transitions

    func testParticipantStateTransitions() {
        let room = makeRoom()
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", state: .joining)
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertEqual(participant.state, .joining)

        // Transition to active
        let activeInfo = TestData.participantInfo(sid: "PA_1", identity: "user-1", state: .active)
        participant.set(info: activeInfo, connectionState: .connected)

        XCTAssertEqual(participant.state, .active)
    }

    // MARK: - Speaker State (via _state direct)

    func testSpeakerStateMutation() {
        let participant = makeRemoteParticipant()

        XCTAssertFalse(participant.isSpeaking)
        XCTAssertEqual(participant.audioLevel, 0.0)

        participant._state.mutate {
            $0.isSpeaking = true
            $0.audioLevel = 0.75
            $0.lastSpokeAt = Date()
        }

        XCTAssertTrue(participant.isSpeaking)
        XCTAssertEqual(participant.audioLevel, 0.75, accuracy: 0.01)
        XCTAssertNotNil(participant.lastSpokeAt)
    }

    // MARK: - Connection Quality

    func testConnectionQualityMutation() {
        let participant = makeRemoteParticipant()

        XCTAssertEqual(participant.connectionQuality, .unknown)

        participant._state.mutate { $0.connectionQuality = .excellent }
        XCTAssertEqual(participant.connectionQuality, .excellent)

        participant._state.mutate { $0.connectionQuality = .poor }
        XCTAssertEqual(participant.connectionQuality, .poor)
    }

    // MARK: - Multiple Kinds

    func testParticipantKinds() {
        let room = makeRoom()
        let kinds: [(Livekit_ParticipantInfo.Kind, Participant.Kind)] = [
            (.standard, .standard),
            (.agent, .agent),
            (.ingress, .ingress),
            (.egress, .egress),
            (.sip, .sip),
        ]

        for (protoKind, expectedKind) in kinds {
            let info = TestData.participantInfo(sid: "PA_\(protoKind)", identity: "user-\(protoKind)", kind: protoKind)
            let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)
            XCTAssertEqual(participant.kind, expectedKind, "Kind mismatch for proto \(protoKind)")
        }
    }

    // MARK: - getTrackPublication(source:)

    func testGetTrackPublicationBySource() {
        let room = makeRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio, source: .microphone)
        let videoTrack = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [audioTrack, videoTrack])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        let audioPub = participant.getTrackPublication(source: .microphone)
        XCTAssertNotNil(audioPub)
        XCTAssertEqual(audioPub?.kind, .audio)

        let videoPub = participant.getTrackPublication(source: .camera)
        XCTAssertNotNil(videoPub)
        XCTAssertEqual(videoPub?.kind, .video)
    }

    func testGetTrackPublicationBySourceReturnsNilForUnknown() {
        let participant = makeRemoteParticipant()
        let result = participant.getTrackPublication(source: .unknown)
        XCTAssertNil(result)
    }

    func testGetTrackPublicationBySourceReturnsNilWhenNoMatch() {
        let room = makeRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio, source: .microphone)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [audioTrack])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        let result = participant.getTrackPublication(source: .camera)
        XCTAssertNil(result)
    }

    func testGetTrackPublicationByName() {
        let room = makeRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_a1", name: "my-mic", type: .audio, source: .microphone)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [audioTrack])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        let result = participant.getTrackPublication(name: "my-mic")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sid, Track.Sid(from: "TR_a1"))
    }

    func testGetTrackPublicationByNameReturnsNil() {
        let participant = makeRemoteParticipant()
        let result = participant.getTrackPublication(name: "nonexistent")
        XCTAssertNil(result)
    }

    // MARK: - Convenience Booleans

    func testIsCameraEnabledFalseWithNoTracks() {
        let participant = makeRemoteParticipant()
        XCTAssertFalse(participant.isCameraEnabled())
    }

    func testIsMicrophoneEnabledFalseWithNoTracks() {
        let participant = makeRemoteParticipant()
        XCTAssertFalse(participant.isMicrophoneEnabled())
    }

    func testIsScreenShareEnabledFalseWithNoTracks() {
        let participant = makeRemoteParticipant()
        XCTAssertFalse(participant.isScreenShareEnabled())
    }

    // MARK: - Participant+Convenience Properties

    func testFirstCameraPublicationFindsCamera() {
        let room = makeRoom()
        let cameraTrack = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [cameraTrack])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertNotNil(participant.firstCameraPublication)
        XCTAssertEqual(participant.firstCameraPublication?.sid, Track.Sid(from: "TR_v1"))
    }

    func testFirstCameraPublicationNilWithNoCamera() {
        let room = makeRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio, source: .microphone)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [audioTrack])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertNil(participant.firstCameraPublication)
    }

    func testFirstScreenSharePublication() {
        let room = makeRoom()
        let screenTrack = TestData.trackInfo(sid: "TR_ss1", name: "screen", type: .video, source: .screenShare)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [screenTrack])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertNotNil(participant.firstScreenSharePublication)
        XCTAssertEqual(participant.firstScreenSharePublication?.sid, Track.Sid(from: "TR_ss1"))
    }

    func testFirstAudioPublication() {
        let room = makeRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio, source: .microphone)
        let info = TestData.participantInfo(sid: "PA_1", identity: "user-1", tracks: [audioTrack])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertNotNil(participant.firstAudioPublication)
        XCTAssertEqual(participant.firstAudioPublication?.sid, Track.Sid(from: "TR_a1"))
    }

    func testFirstTrackEncryptionTypeDefault() {
        let participant = makeRemoteParticipant()
        XCTAssertEqual(participant.firstTrackEncryptionType, .none)
    }

    // MARK: - Participant+Agent

    func testIsAgentTrueForAgentKind() {
        let room = makeRoom()
        let info = TestData.participantInfo(sid: "PA_agent", identity: "agent-1", kind: .agent)
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertTrue(participant.isAgent)
    }

    func testIsAgentFalseForStandardKind() {
        let room = makeRoom()
        let info = TestData.participantInfo(sid: "PA_std", identity: "user-1", kind: .standard)
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)

        XCTAssertFalse(participant.isAgent)
    }

    func testAgentStateDefaultsToIdle() {
        let participant = makeRemoteParticipant()
        XCTAssertEqual(participant.agentState, .idle)
    }

    func testAgentStateStringReturnsRawValue() {
        let participant = makeRemoteParticipant()
        XCTAssertEqual(participant.agentStateString, AgentState.idle.rawValue)
    }

    // MARK: - set(permissions:)

    func testSetPermissionsReturnsTrueOnChange() {
        let participant = makeRemoteParticipant()
        let newPerms = ParticipantPermissions(canSubscribe: true, canPublish: false, canPublishData: false)

        let changed = participant.set(permissions: newPerms)

        XCTAssertTrue(changed)
        XCTAssertFalse(participant.permissions.canPublish)
    }

    func testSetPermissionsReturnsFalseWhenUnchanged() {
        let participant = makeRemoteParticipant()
        // Default permissions from TestData have canPublish=true, canSubscribe=true, canPublishData=true
        let samePerms = participant.permissions

        let changed = participant.set(permissions: samePerms)

        XCTAssertFalse(changed)
    }

    // MARK: - set(enabledPublishCodecs:)

    func testSetEnabledPublishCodecsParsesMimeTypes() {
        let participant = makeRemoteParticipant()

        let codecs = [
            Livekit_Codec.with { $0.mime = "video/vp8" },
            Livekit_Codec.with { $0.mime = "video/h264" },
        ]

        participant.set(enabledPublishCodecs: codecs)

        let enabled = participant._internalState.read { $0.enabledPublishVideoCodecs }
        XCTAssertEqual(enabled.count, 2)
    }

    // MARK: - cleanUp

    func testCleanUpResetsState() async {
        let participant = makeRemoteParticipant()
        XCTAssertNotNil(participant.sid)
        XCTAssertNotNil(participant.identity)

        await participant.cleanUp(notify: false)

        XCTAssertNil(participant.sid)
        XCTAssertNil(participant.identity)
        XCTAssertNil(participant.name)
        XCTAssertEqual(participant.connectionQuality, .unknown)
    }

    // MARK: - Local Participant set(info:)

    func testLocalParticipantSetInfo() {
        let room = makeRoom()
        let info = TestData.participantInfo(
            sid: "PA_local2",
            identity: "local-2",
            name: "Local Two",
            metadata: "local-meta",
            attributes: ["key": "value"],
            canPublish: true,
            canSubscribe: true,
            canPublishData: true
        )

        room.localParticipant.set(info: info, connectionState: .connected)

        XCTAssertEqual(room.localParticipant.sid?.stringValue, "PA_local2")
        XCTAssertEqual(room.localParticipant.identity?.stringValue, "local-2")
        XCTAssertEqual(room.localParticipant.name, "Local Two")
        XCTAssertEqual(room.localParticipant.metadata, "local-meta")
        XCTAssertEqual(room.localParticipant.attributes["key"], "value")
        XCTAssertTrue(room.localParticipant.permissions.canPublish)
    }
}
