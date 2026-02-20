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

/// Tests for RemoteTrackPublication internal state management and computed properties.
class RemoteTrackPublicationTests: LKTestCase {
    // MARK: - Helper

    private func makeRoom() -> Room {
        let room = Room()
        room._state.mutate { $0.connectionState = .connected }
        let localInfo = TestData.participantInfo(sid: "PA_local", identity: "local-user")
        room.localParticipant.set(info: localInfo, connectionState: .connected)
        return room
    }

    private func makeRemoteParticipantWithTrack(
        room: Room,
        participantSid: String = "PA_r1",
        identity: String = "remote-1",
        trackSid: String = "TR_audio1",
        trackName: String = "mic",
        trackType: Livekit_TrackType = .audio,
        trackSource: Livekit_TrackSource = .microphone,
        muted: Bool = false
    ) -> (RemoteParticipant, RemoteTrackPublication) {
        let trackInfo = TestData.trackInfo(sid: trackSid, name: trackName, type: trackType, source: trackSource, muted: muted)
        let info = TestData.participantInfo(sid: participantSid, identity: identity, tracks: [trackInfo])
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)
        room._state.mutate {
            $0.remoteParticipants[Participant.Identity(from: identity)] = participant
        }
        let pub = participant.trackPublications[Track.Sid(from: trackSid)]! as! RemoteTrackPublication
        return (participant, pub)
    }

    // MARK: - Init and Computed Properties

    func testInitFromTrackInfoSetsProperties() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(
            room: room,
            trackSid: "TR_v1",
            trackName: "camera",
            trackType: .video,
            trackSource: .camera
        )

        XCTAssertEqual(pub.sid, Track.Sid(from: "TR_v1"))
        XCTAssertEqual(pub.kind, .video)
        XCTAssertEqual(pub.source, .camera)
        XCTAssertEqual(pub.name, "camera")
    }

    func testSubscriptionStateDefault() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room)

        // No track attached, subscription allowed by default
        XCTAssertTrue(pub.isSubscriptionAllowed)
        XCTAssertFalse(pub.isSubscribed) // no track set
        XCTAssertEqual(pub.subscriptionState, .unsubscribed)
    }

    func testSubscriptionStateNotAllowed() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room)

        pub.set(subscriptionAllowed: false)

        XCTAssertFalse(pub.isSubscriptionAllowed)
        XCTAssertFalse(pub.isSubscribed)
        XCTAssertEqual(pub.subscriptionState, .notAllowed)
    }

    func testIsDesiredDefault() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room)

        XCTAssertTrue(pub.isDesired)
    }

    func testIsMutedFallsBackToMetadata() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room, muted: true)

        // No track attached — isMuted should fall back to isMetadataMuted
        XCTAssertTrue(pub.isMuted)
    }

    func testIsMutedWhenNotMuted() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room, muted: false)

        XCTAssertFalse(pub.isMuted)
    }

    // MARK: - set(metadataMuted:)

    func testSetMetadataMutedUpdatesState() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room, muted: false)

        XCTAssertFalse(pub._state.read { $0.isMetadataMuted })

        pub.set(metadataMuted: true)

        XCTAssertTrue(pub._state.read { $0.isMetadataMuted })
        XCTAssertTrue(pub.isMuted) // falls back to metadata since no track
    }

    func testSetMetadataMutedNoOpWhenSameValue() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room, muted: true)

        // Already muted — should be a no-op
        pub.set(metadataMuted: true)

        XCTAssertTrue(pub._state.read { $0.isMetadataMuted })
    }

    func testSetMetadataMutedUnmutes() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room, muted: true)

        pub.set(metadataMuted: false)

        XCTAssertFalse(pub._state.read { $0.isMetadataMuted })
        XCTAssertFalse(pub.isMuted)
    }

    // MARK: - set(subscriptionAllowed:)

    func testSetSubscriptionAllowedUpdatesState() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room)

        XCTAssertTrue(pub.isSubscriptionAllowed)

        pub.set(subscriptionAllowed: false)

        XCTAssertFalse(pub.isSubscriptionAllowed)
        XCTAssertEqual(pub.subscriptionState, .notAllowed)
    }

    func testSetSubscriptionAllowedNoOpWhenSameValue() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room)

        pub.set(subscriptionAllowed: true) // already true

        XCTAssertTrue(pub.isSubscriptionAllowed)
    }

    func testSetSubscriptionAllowedReEnables() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room)

        pub.set(subscriptionAllowed: false)
        XCTAssertFalse(pub.isSubscriptionAllowed)

        pub.set(subscriptionAllowed: true)
        XCTAssertTrue(pub.isSubscriptionAllowed)
    }

    // MARK: - resetTrackSettings

    func testResetTrackSettingsDefaultsToEnabled() {
        let room = makeRoom()
        // Default RoomOptions has adaptiveStream = false
        let (_, pub) = makeRemoteParticipantWithTrack(room: room, trackType: .video, trackSource: .camera)

        // Manually set track settings to disabled
        pub._state.mutate { $0.trackSettings = TrackSettings(enabled: false) }
        XCTAssertFalse(pub.isEnabled)

        pub.resetTrackSettings()

        // With adaptiveStream disabled, reset should set enabled = true
        XCTAssertTrue(pub.isEnabled)
    }

    func testResetTrackSettingsWithAdaptiveStreamDisablesTrack() {
        let room = Room(roomOptions: RoomOptions(adaptiveStream: true))
        room._state.mutate { $0.connectionState = .connected }
        let localInfo = TestData.participantInfo(sid: "PA_local", identity: "local-user")
        room.localParticipant.set(info: localInfo, connectionState: .connected)

        let trackInfo = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let pInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", tracks: [trackInfo])
        let participant = RemoteParticipant(info: pInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = participant }

        let pub = participant.trackPublications[Track.Sid(from: "TR_v1")]! as! RemoteTrackPublication

        pub.resetTrackSettings()

        // With adaptiveStream enabled on a video track, initially disabled
        XCTAssertFalse(pub.isEnabled)
    }

    func testResetTrackSettingsAudioNotAffectedByAdaptiveStream() {
        let room = Room(roomOptions: RoomOptions(adaptiveStream: true))
        room._state.mutate { $0.connectionState = .connected }
        let localInfo = TestData.participantInfo(sid: "PA_local", identity: "local-user")
        room.localParticipant.set(info: localInfo, connectionState: .connected)

        let trackInfo = TestData.trackInfo(sid: "TR_a1", name: "mic", type: .audio, source: .microphone)
        let pInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", tracks: [trackInfo])
        let participant = RemoteParticipant(info: pInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = participant }

        let pub = participant.trackPublications[Track.Sid(from: "TR_a1")]! as! RemoteTrackPublication

        pub.resetTrackSettings()

        // Audio tracks are not affected by adaptiveStream — should be enabled
        XCTAssertTrue(pub.isEnabled)
    }

    // MARK: - updateFromInfo

    func testUpdateFromInfoUpdatesNameAndMuted() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room, trackSid: "TR_a1", trackName: "mic", muted: false)

        XCTAssertEqual(pub.name, "mic")
        XCTAssertFalse(pub._state.read { $0.isMetadataMuted })

        // Update with new info
        var updatedInfo = TestData.trackInfo(sid: "TR_a1", name: "microphone-updated", type: .audio, muted: true)
        updatedInfo.simulcast = true
        updatedInfo.mimeType = "audio/opus"
        pub.updateFromInfo(info: updatedInfo)

        XCTAssertEqual(pub.name, "microphone-updated")
        XCTAssertTrue(pub.isSimulcasted)
        XCTAssertEqual(pub.mimeType, "audio/opus")
        XCTAssertTrue(pub._state.read { $0.isMetadataMuted })
    }

    func testUpdateFromInfoSetsDimensionsForVideo() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(
            room: room, trackSid: "TR_v1", trackName: "camera",
            trackType: .video, trackSource: .camera
        )

        var updatedInfo = Livekit_TrackInfo.with {
            $0.sid = "TR_v1"
            $0.name = "camera"
            $0.type = .video
            $0.source = .camera
            $0.width = 1920
            $0.height = 1080
        }
        pub.updateFromInfo(info: updatedInfo)

        XCTAssertEqual(pub.dimensions?.width, 1920)
        XCTAssertEqual(pub.dimensions?.height, 1080)
    }

    // MARK: - TrackPublication Base

    func testTrackPublicationRequireParticipantWithNilThrows() async {
        let room = makeRoom()
        let trackInfo = TestData.trackInfo(sid: "TR_orphan")
        let pub = RemoteTrackPublication(info: trackInfo, participant: room.localParticipant)
        // Detach participant
        pub.participant = nil

        do {
            _ = try await pub.requireParticipant()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is LiveKitError)
        }
    }

    func testTrackPublicationEncryptionTypeDefault() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room)

        XCTAssertEqual(pub.encryptionType, .none)
    }

    func testStreamStateDefault() {
        let room = makeRoom()
        let (_, pub) = makeRemoteParticipantWithTrack(room: room)

        XCTAssertEqual(pub.streamState, .paused)
    }
}
