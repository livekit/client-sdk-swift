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

/// Tests for Room's SignalClientDelegate method implementations.
/// These test the business logic in Room+SignalClientDelegate.swift by calling
/// the delegate methods directly with test data, bypassing the WebSocket layer.
class RoomSignalDelegateTests: LKTestCase {
    // MARK: - Helper

    /// Creates a Room in a simulated connected state suitable for delegate testing.
    private func makeConnectedRoom() -> Room {
        let room = Room()
        room._state.mutate {
            $0.connectionState = .connected
        }
        // Set local participant info so it has a valid identity/sid
        let localInfo = TestData.participantInfo(sid: "PA_local", identity: "local-user", name: "Local User")
        room.localParticipant.set(info: localInfo, connectionState: .connected)
        return room
    }

    // MARK: - didReceiveConnectResponse (Join)

    func testJoinResponseSetsRoomProperties() async {
        let room = Room()
        let joinResponse = TestData.joinResponse(
            room: TestData.roomInfo(sid: "RM_abc", name: "my-room", metadata: "room-meta", maxParticipants: 50, numParticipants: 3, numPublishers: 1, creationTime: 1_700_000_000),
            participant: TestData.participantInfo(sid: "PA_local", identity: "local-user"),
            serverInfo: TestData.serverInfo(version: "1.8.0", region: "us-west-2", nodeID: "node-xyz")
        )

        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(joinResponse))

        XCTAssertEqual(room.sid?.stringValue, "RM_abc")
        XCTAssertEqual(room.name, "my-room")
        XCTAssertEqual(room.metadata, "room-meta")
        XCTAssertEqual(room.maxParticipants, 50)
        XCTAssertEqual(room.participantCount, 3)
        XCTAssertEqual(room.publishersCount, 1)
        XCTAssertEqual(room.serverVersion, "1.8.0")
        XCTAssertEqual(room.serverRegion, "us-west-2")
        XCTAssertEqual(room.serverNodeId, "node-xyz")
        XCTAssertNotNil(room.creationTime)
    }

    func testJoinResponseSetsLocalParticipant() async {
        let room = Room()
        let joinResponse = TestData.joinResponse(
            participant: TestData.participantInfo(sid: "PA_me", identity: "my-identity", name: "My Name")
        )

        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(joinResponse))

        XCTAssertEqual(room.localParticipant.sid?.stringValue, "PA_me")
        XCTAssertEqual(room.localParticipant.identity?.stringValue, "my-identity")
        XCTAssertEqual(room.localParticipant.name, "My Name")
    }

    func testJoinResponseAddsOtherParticipants() async {
        let room = Room()
        let remote1 = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", name: "Remote 1")
        let remote2 = TestData.participantInfo(sid: "PA_r2", identity: "remote-2", name: "Remote 2")
        let joinResponse = TestData.joinResponse(otherParticipants: [remote1, remote2])

        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(joinResponse))

        XCTAssertEqual(room.remoteParticipants.count, 2)
        let identity1 = Participant.Identity(from: "remote-1")
        let identity2 = Participant.Identity(from: "remote-2")
        XCTAssertNotNil(room.remoteParticipants[identity1])
        XCTAssertNotNil(room.remoteParticipants[identity2])
        XCTAssertEqual(room.remoteParticipants[identity1]?.name, "Remote 1")
    }

    func testJoinResponseWithCreationTimeMs() async {
        let room = Room()
        let roomProto = Livekit_Room.with {
            $0.sid = "RM_test"
            $0.name = "test"
            $0.creationTimeMs = 1_700_000_000_500 // ms precision
        }
        let joinResponse = TestData.joinResponse(room: roomProto)

        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(joinResponse))

        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000.5)
        XCTAssertEqual(room.creationTime?.timeIntervalSince1970 ?? 0, expectedDate.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - didUpdateRoom

    func testUpdateRoomSetsMetadata() async {
        let room = makeConnectedRoom()
        let roomUpdate = Livekit_Room.with {
            $0.metadata = "updated-meta"
            $0.activeRecording = true
            $0.numParticipants = 5
            $0.numPublishers = 2
        }

        await room.signalClient(room.signalClient, didUpdateRoom: roomUpdate)

        XCTAssertEqual(room.metadata, "updated-meta")
        XCTAssertTrue(room.isRecording)
        XCTAssertEqual(room.participantCount, 5)
        XCTAssertEqual(room.publishersCount, 2)
    }

    // MARK: - didUpdateParticipants

    func testUpdateParticipantsAddsNewRemoteParticipant() async {
        let room = makeConnectedRoom()
        let newParticipant = TestData.participantInfo(sid: "PA_new", identity: "new-user", name: "New User")

        await room.signalClient(room.signalClient, didUpdateParticipants: [newParticipant])

        let identity = Participant.Identity(from: "new-user")
        XCTAssertEqual(room.remoteParticipants.count, 1)
        XCTAssertEqual(room.remoteParticipants[identity]?.name, "New User")
        XCTAssertEqual(room.remoteParticipants[identity]?.sid?.stringValue, "PA_new")
    }

    func testUpdateParticipantsUpdatesExistingParticipant() async {
        let room = makeConnectedRoom()
        // Add initial participant
        let initial = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", name: "Old Name", metadata: "old")
        await room.signalClient(room.signalClient, didUpdateParticipants: [initial])

        // Update the same participant
        let updated = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", name: "New Name", metadata: "new")
        await room.signalClient(room.signalClient, didUpdateParticipants: [updated])

        let identity = Participant.Identity(from: "remote-1")
        XCTAssertEqual(room.remoteParticipants.count, 1)
        XCTAssertEqual(room.remoteParticipants[identity]?.name, "New Name")
        XCTAssertEqual(room.remoteParticipants[identity]?.metadata, "new")
    }

    func testUpdateParticipantsRemovesDisconnectedParticipant() async {
        let room = makeConnectedRoom()
        // Add participant first
        let participant = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", name: "User 1")
        await room.signalClient(room.signalClient, didUpdateParticipants: [participant])
        XCTAssertEqual(room.remoteParticipants.count, 1)

        // Disconnect the participant
        let disconnected = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", state: .disconnected)
        await room.signalClient(room.signalClient, didUpdateParticipants: [disconnected])

        // Allow async cleanup
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(room.remoteParticipants.count, 0)
    }

    func testUpdateParticipantsUpdatesLocalParticipant() async {
        let room = makeConnectedRoom()
        // Update local participant metadata
        let localUpdate = TestData.participantInfo(sid: "PA_local", identity: "local-user", name: "Updated Local", metadata: "new-meta")
        await room.signalClient(room.signalClient, didUpdateParticipants: [localUpdate])

        XCTAssertEqual(room.localParticipant.name, "Updated Local")
        XCTAssertEqual(room.localParticipant.metadata, "new-meta")
        // Should not create a remote participant for local identity
        XCTAssertEqual(room.remoteParticipants.count, 0)
    }

    func testUpdateParticipantsAddsMultipleNewParticipants() async {
        let room = makeConnectedRoom()
        let p1 = TestData.participantInfo(sid: "PA_1", identity: "user-1", name: "User 1")
        let p2 = TestData.participantInfo(sid: "PA_2", identity: "user-2", name: "User 2")
        let p3 = TestData.participantInfo(sid: "PA_3", identity: "user-3", name: "User 3")

        await room.signalClient(room.signalClient, didUpdateParticipants: [p1, p2, p3])

        XCTAssertEqual(room.remoteParticipants.count, 3)
    }

    // MARK: - didUpdateSpeakers

    func testUpdateSpeakersSetsSpeakingState() async {
        let room = makeConnectedRoom()
        // Add remote participant
        let remoteInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        await room.signalClient(room.signalClient, didUpdateParticipants: [remoteInfo])

        let identity = Participant.Identity(from: "remote-1")
        let remote = room.remoteParticipants[identity]!

        // Set speaker active
        let speaker = TestData.speakerInfo(sid: "PA_r1", level: 0.9, active: true)
        await room.signalClient(room.signalClient, didUpdateSpeakers: [speaker])

        XCTAssertTrue(remote.isSpeaking)
        XCTAssertEqual(remote.audioLevel, 0.9, accuracy: 0.01)
        XCTAssertNotNil(remote.lastSpokeAt)
    }

    func testUpdateSpeakersStopsSpeaking() async {
        let room = makeConnectedRoom()
        let remoteInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        await room.signalClient(room.signalClient, didUpdateParticipants: [remoteInfo])

        // Start speaking
        let speakerOn = TestData.speakerInfo(sid: "PA_r1", level: 0.8, active: true)
        await room.signalClient(room.signalClient, didUpdateSpeakers: [speakerOn])

        let identity = Participant.Identity(from: "remote-1")
        let remote = room.remoteParticipants[identity]!
        XCTAssertTrue(remote.isSpeaking)

        // Stop speaking
        let speakerOff = TestData.speakerInfo(sid: "PA_r1", level: 0.0, active: false)
        await room.signalClient(room.signalClient, didUpdateSpeakers: [speakerOff])

        XCTAssertFalse(remote.isSpeaking)
    }

    func testUpdateSpeakersUpdatesActiveSpeakers() async {
        let room = makeConnectedRoom()
        let r1 = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        let r2 = TestData.participantInfo(sid: "PA_r2", identity: "remote-2")
        await room.signalClient(room.signalClient, didUpdateParticipants: [r1, r2])

        let s1 = TestData.speakerInfo(sid: "PA_r1", level: 0.5, active: true)
        let s2 = TestData.speakerInfo(sid: "PA_r2", level: 0.9, active: true)
        await room.signalClient(room.signalClient, didUpdateSpeakers: [s1, s2])

        XCTAssertEqual(room.activeSpeakers.count, 2)
    }

    func testUpdateSpeakersForLocalParticipant() async {
        let room = makeConnectedRoom()

        let speaker = TestData.speakerInfo(sid: "PA_local", level: 0.7, active: true)
        await room.signalClient(room.signalClient, didUpdateSpeakers: [speaker])

        XCTAssertTrue(room.localParticipant.isSpeaking)
        XCTAssertEqual(room.localParticipant.audioLevel, 0.7, accuracy: 0.01)
    }

    // MARK: - didUpdateConnectionQuality

    func testUpdateConnectionQualityForRemoteParticipant() async {
        let room = makeConnectedRoom()
        let remoteInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        await room.signalClient(room.signalClient, didUpdateParticipants: [remoteInfo])

        let quality = TestData.connectionQualityInfo(participantSid: "PA_r1", quality: .excellent)
        await room.signalClient(room.signalClient, didUpdateConnectionQuality: [quality])

        let identity = Participant.Identity(from: "remote-1")
        XCTAssertEqual(room.remoteParticipants[identity]?.connectionQuality, .excellent)
    }

    func testUpdateConnectionQualityForLocalParticipant() async {
        let room = makeConnectedRoom()

        let quality = TestData.connectionQualityInfo(participantSid: "PA_local", quality: .poor)
        await room.signalClient(room.signalClient, didUpdateConnectionQuality: [quality])

        XCTAssertEqual(room.localParticipant.connectionQuality, .poor)
    }

    func testUpdateConnectionQualityMultipleParticipants() async {
        let room = makeConnectedRoom()
        let r1 = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        let r2 = TestData.participantInfo(sid: "PA_r2", identity: "remote-2")
        await room.signalClient(room.signalClient, didUpdateParticipants: [r1, r2])

        let q1 = TestData.connectionQualityInfo(participantSid: "PA_r1", quality: .good)
        let q2 = TestData.connectionQualityInfo(participantSid: "PA_r2", quality: .poor)
        await room.signalClient(room.signalClient, didUpdateConnectionQuality: [q1, q2])

        let id1 = Participant.Identity(from: "remote-1")
        let id2 = Participant.Identity(from: "remote-2")
        XCTAssertEqual(room.remoteParticipants[id1]?.connectionQuality, .good)
        XCTAssertEqual(room.remoteParticipants[id2]?.connectionQuality, .poor)
    }

    // MARK: - didUpdateToken

    func testUpdateTokenUpdatesRoomToken() async {
        let room = makeConnectedRoom()
        room._state.mutate { $0.token = "old-token" }

        await room.signalClient(room.signalClient, didUpdateToken: "new-refreshed-token")

        XCTAssertEqual(room.token, "new-refreshed-token")
    }

    // MARK: - didReceiveLeave

    func testLeaveDisconnectCleansUpRoom() async {
        let room = makeConnectedRoom()
        let remoteInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        await room.signalClient(room.signalClient, didUpdateParticipants: [remoteInfo])
        XCTAssertEqual(room.remoteParticipants.count, 1)

        await room.signalClient(room.signalClient, didReceiveLeave: .disconnect, reason: .clientInitiated, regions: nil)

        // Allow async cleanup
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(room.connectionState, .disconnected)
    }

    func testLeaveReconnectSetsNextReconnectMode() async {
        let room = makeConnectedRoom()

        await room.signalClient(room.signalClient, didReceiveLeave: .reconnect, reason: .unknownReason, regions: nil)

        // The nextReconnectMode should be set to .full
        let nextMode = room._state.read { $0.nextReconnectMode }
        XCTAssertEqual(nextMode, .full)
    }

    // MARK: - didUpdateParticipants with tracks

    func testUpdateParticipantsWithTracksCreatesPublications() async {
        let room = makeConnectedRoom()
        let track = TestData.trackInfo(sid: "TR_audio1", name: "microphone", type: .audio, source: .microphone)
        let participant = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", tracks: [track])

        await room.signalClient(room.signalClient, didUpdateParticipants: [participant])

        let identity = Participant.Identity(from: "remote-1")
        let remote = room.remoteParticipants[identity]
        XCTAssertNotNil(remote)
        XCTAssertEqual(remote?.trackPublications.count, 1)
        let trackSid = Track.Sid(from: "TR_audio1")
        XCTAssertNotNil(remote?.trackPublications[trackSid])
    }

    // MARK: - didUpdateSubscriptionPermission

    func testSubscriptionPermissionUpdateSetsAllowed() async {
        let room = makeConnectedRoom()
        let trackInfo = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let pInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", tracks: [trackInfo])
        let remote = RemoteParticipant(info: pInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = remote }

        let update = TestData.subscriptionPermissionUpdate(participantSid: "PA_r1", trackSid: "TR_v1", allowed: false)
        await room.signalClient(room.signalClient, didUpdateSubscriptionPermission: update)

        let pub = remote.trackPublications[Track.Sid(from: "TR_v1")] as? RemoteTrackPublication
        XCTAssertFalse(pub?.isSubscriptionAllowed ?? true)
        XCTAssertEqual(pub?.subscriptionState, .notAllowed)
    }

    func testSubscriptionPermissionUpdateReEnablesSubscription() async {
        let room = makeConnectedRoom()
        let trackInfo = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let pInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", tracks: [trackInfo])
        let remote = RemoteParticipant(info: pInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = remote }

        // Disable first
        let disable = TestData.subscriptionPermissionUpdate(participantSid: "PA_r1", trackSid: "TR_v1", allowed: false)
        await room.signalClient(room.signalClient, didUpdateSubscriptionPermission: disable)
        let disabledPub = remote.trackPublications[Track.Sid(from: "TR_v1")] as? RemoteTrackPublication
        XCTAssertFalse(disabledPub?.isSubscriptionAllowed ?? true)

        // Re-enable
        let enable = TestData.subscriptionPermissionUpdate(participantSid: "PA_r1", trackSid: "TR_v1", allowed: true)
        await room.signalClient(room.signalClient, didUpdateSubscriptionPermission: enable)

        let pub = remote.trackPublications[Track.Sid(from: "TR_v1")] as? RemoteTrackPublication
        XCTAssertTrue(pub?.isSubscriptionAllowed ?? false)
    }

    func testSubscriptionPermissionUpdateUnknownParticipantNoOp() async {
        let room = makeConnectedRoom()
        let participantsBefore = room.remoteParticipants.count
        let update = TestData.subscriptionPermissionUpdate(participantSid: "PA_unknown", trackSid: "TR_v1", allowed: false)
        await room.signalClient(room.signalClient, didUpdateSubscriptionPermission: update)

        // Room state unchanged
        XCTAssertEqual(room.remoteParticipants.count, participantsBefore)
    }

    func testSubscriptionPermissionUpdateUnknownTrackNoOp() async {
        let room = makeConnectedRoom()
        let pInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        let remote = RemoteParticipant(info: pInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = remote }

        // Track doesn't exist on participant — should be a no-op
        let update = TestData.subscriptionPermissionUpdate(participantSid: "PA_r1", trackSid: "TR_nonexistent", allowed: false)
        await room.signalClient(room.signalClient, didUpdateSubscriptionPermission: update)

        // Participant still exists, no publications changed
        XCTAssertEqual(remote.trackPublications.count, 0)
    }

    // MARK: - didUpdateTrackStreamStates

    func testStreamStateUpdateSetsActive() async {
        let room = makeConnectedRoom()
        let trackInfo = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let pInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", tracks: [trackInfo])
        let remote = RemoteParticipant(info: pInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = remote }

        let stateInfo = TestData.streamStateInfo(participantSid: "PA_r1", trackSid: "TR_v1", state: .active)
        await room.signalClient(room.signalClient, didUpdateTrackStreamStates: [stateInfo])

        let pub = remote.trackPublications[Track.Sid(from: "TR_v1")] as? RemoteTrackPublication
        XCTAssertEqual(pub?.streamState, .active)
    }

    func testStreamStateUpdateSetsPaused() async {
        let room = makeConnectedRoom()
        let trackInfo = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let pInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", tracks: [trackInfo])
        let remote = RemoteParticipant(info: pInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = remote }

        // Set to active first
        let active = TestData.streamStateInfo(participantSid: "PA_r1", trackSid: "TR_v1", state: .active)
        await room.signalClient(room.signalClient, didUpdateTrackStreamStates: [active])
        let pub = remote.trackPublications[Track.Sid(from: "TR_v1")] as? RemoteTrackPublication
        XCTAssertEqual(pub?.streamState, .active)

        // Set to paused
        let paused = TestData.streamStateInfo(participantSid: "PA_r1", trackSid: "TR_v1", state: .paused)
        await room.signalClient(room.signalClient, didUpdateTrackStreamStates: [paused])
        XCTAssertEqual(pub?.streamState, .paused)
    }

    func testStreamStateUpdateMultipleTracks() async {
        let room = makeConnectedRoom()
        let trackV = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let trackA = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio, source: .microphone)
        let pInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", tracks: [trackV, trackA])
        let remote = RemoteParticipant(info: pInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = remote }

        let s1 = TestData.streamStateInfo(participantSid: "PA_r1", trackSid: "TR_v1", state: .active)
        let s2 = TestData.streamStateInfo(participantSid: "PA_r1", trackSid: "TR_a1", state: .active)
        await room.signalClient(room.signalClient, didUpdateTrackStreamStates: [s1, s2])

        let pubV = remote.trackPublications[Track.Sid(from: "TR_v1")] as? RemoteTrackPublication
        let pubA = remote.trackPublications[Track.Sid(from: "TR_a1")] as? RemoteTrackPublication
        XCTAssertEqual(pubV?.streamState, .active)
        XCTAssertEqual(pubA?.streamState, .active)
    }

    func testStreamStateUpdateUnknownParticipantNoOp() async {
        let room = makeConnectedRoom()
        let participantsBefore = room.remoteParticipants.count
        let stateInfo = TestData.streamStateInfo(participantSid: "PA_unknown", trackSid: "TR_v1", state: .active)
        await room.signalClient(room.signalClient, didUpdateTrackStreamStates: [stateInfo])

        // State unchanged
        XCTAssertEqual(room.remoteParticipants.count, participantsBefore)
    }

    // MARK: - didReceiveRoomMoved

    func testRoomMovedUpdatesRoomInfo() async {
        let room = makeConnectedRoom()
        let newRoom = TestData.roomInfo(sid: "RM_new", name: "new-room", metadata: "moved")
        let response = TestData.roomMovedResponse(room: newRoom, token: "moved-token")

        await room.signalClient(room.signalClient, didReceiveRoomMoved: response)

        XCTAssertEqual(room.sid?.stringValue, "RM_new")
        XCTAssertEqual(room.name, "new-room")
        XCTAssertEqual(room.metadata, "moved")
        XCTAssertEqual(room.token, "moved-token")
    }

    func testRoomMovedUpdatesLocalParticipant() async {
        let room = makeConnectedRoom()
        let newRoom = TestData.roomInfo(sid: "RM_new", name: "new-room")
        let newLocal = TestData.participantInfo(sid: "PA_local_new", identity: "local-user", name: "Moved Local")
        let response = TestData.roomMovedResponse(room: newRoom, participant: newLocal)

        await room.signalClient(room.signalClient, didReceiveRoomMoved: response)

        XCTAssertEqual(room.localParticipant.sid?.stringValue, "PA_local_new")
        XCTAssertEqual(room.localParticipant.name, "Moved Local")
    }

    func testRoomMovedDisconnectsOldParticipants() async {
        let room = makeConnectedRoom()
        // Add remote participant to old room
        let oldRemote = TestData.participantInfo(sid: "PA_old", identity: "old-remote")
        await room.signalClient(room.signalClient, didUpdateParticipants: [oldRemote])
        XCTAssertEqual(room.remoteParticipants.count, 1)

        let newRoom = TestData.roomInfo(sid: "RM_new", name: "new-room")
        let response = TestData.roomMovedResponse(room: newRoom)
        await room.signalClient(room.signalClient, didReceiveRoomMoved: response)
        // Allow async cleanup
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Old participants should be disconnected
        XCTAssertEqual(room.remoteParticipants.count, 0)
    }

    func testRoomMovedAddsNewParticipants() async {
        let room = makeConnectedRoom()
        let newRoom = TestData.roomInfo(sid: "RM_new", name: "new-room")
        let newRemote = TestData.participantInfo(sid: "PA_new", identity: "new-remote", name: "New Remote")
        let response = TestData.roomMovedResponse(room: newRoom, otherParticipants: [newRemote])

        await room.signalClient(room.signalClient, didReceiveRoomMoved: response)

        let identity = Participant.Identity(from: "new-remote")
        XCTAssertNotNil(room.remoteParticipants[identity])
        XCTAssertEqual(room.remoteParticipants[identity]?.name, "New Remote")
    }

    func testRoomMovedWithTokenOnlyUpdatesToken() async {
        let room = makeConnectedRoom()
        room._state.mutate { $0.token = "old-token" }

        // Room moved with only token, no room info
        let response = TestData.roomMovedResponse(token: "token-only")
        await room.signalClient(room.signalClient, didReceiveRoomMoved: response)

        XCTAssertEqual(room.token, "token-only")
    }

    // MARK: - didUpdateRemoteMute

    func testRemoteMuteNoPublicationIsNoOp() async {
        let room = makeConnectedRoom()
        let pubCount = room.localParticipant.trackPublications.count
        // No local publications — should be no-op
        await room.signalClient(room.signalClient, didUpdateRemoteMute: Track.Sid(from: "TR_nonexistent"), muted: true)

        XCTAssertEqual(room.localParticipant.trackPublications.count, pubCount)
    }

    // MARK: - didSubscribeTrack

    func testSubscribeTrackNoPublicationIsNoOp() async {
        let room = makeConnectedRoom()
        let pubCount = room.localParticipant.trackPublications.count
        // No matching local publication — should be no-op
        await room.signalClient(room.signalClient, didSubscribeTrack: Track.Sid(from: "TR_nonexistent"))

        XCTAssertEqual(room.localParticipant.trackPublications.count, pubCount)
    }

    // MARK: - didUpdateSubscribedCodecs

    func testSubscribedCodecsNoDynacastIsNoOp() async {
        // Room with dynacast disabled (default)
        let room = makeConnectedRoom()
        let metadata = room.metadata
        await room.signalClient(room.signalClient, didUpdateSubscribedCodecs: [], qualities: [], forTrackSid: "TR_v1")

        // Should return early without error, state unchanged
        XCTAssertEqual(room.metadata, metadata)
    }

    // MARK: - didReceiveLeave with resume action

    func testLeaveResumeCleansUpSignalClient() async {
        let room = makeConnectedRoom()
        await room.signalClient(room.signalClient, didReceiveLeave: .resume, reason: .unknownReason, regions: nil)
        // Allow async cleanup
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Signal client should be cleaned up (disconnected)
        let signalState = await room.signalClient.connectionState
        XCTAssertEqual(signalState, .disconnected)
    }
}
