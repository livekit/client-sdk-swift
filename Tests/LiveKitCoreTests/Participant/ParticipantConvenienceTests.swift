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

/// Tests for Participant convenience properties (firstCameraPublication, etc.)
/// and Participant+Agent extensions (isAgent, agentState, etc.).
class ParticipantConvenienceTests: LKTestCase {
    private func makeHelper() -> RoomTestHelper {
        RoomTestHelper()
    }

    // MARK: - firstCameraPublication

    func testFirstCameraPublicationWithCamera() {
        let helper = makeHelper()
        let cameraTrack = TestData.trackInfo(sid: "TR_cam", name: "camera", type: .video, source: .camera)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [cameraTrack])

        XCTAssertNotNil(participant.firstCameraPublication)
        XCTAssertEqual(participant.firstCameraPublication?.sid, Track.Sid(from: "TR_cam"))
    }

    func testFirstCameraPublicationWithNoCameraTracks() {
        let helper = makeHelper()
        let audioTrack = TestData.trackInfo(sid: "TR_mic", name: "mic", type: .audio, source: .microphone)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [audioTrack])

        XCTAssertNil(participant.firstCameraPublication)
    }

    func testFirstCameraPublicationWithNoTracks() {
        let helper = makeHelper()
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [])

        XCTAssertNil(participant.firstCameraPublication)
    }

    // MARK: - firstScreenSharePublication

    func testFirstScreenSharePublicationWithScreenShare() {
        let helper = makeHelper()
        let screenTrack = TestData.trackInfo(sid: "TR_screen", name: "screen", type: .video, source: .screenShare)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [screenTrack])

        XCTAssertNotNil(participant.firstScreenSharePublication)
        XCTAssertEqual(participant.firstScreenSharePublication?.sid, Track.Sid(from: "TR_screen"))
    }

    func testFirstScreenSharePublicationWithNoScreenShare() {
        let helper = makeHelper()
        let cameraTrack = TestData.trackInfo(sid: "TR_cam", name: "camera", type: .video, source: .camera)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [cameraTrack])

        XCTAssertNil(participant.firstScreenSharePublication)
    }

    // MARK: - firstAudioPublication

    func testFirstAudioPublication() {
        let helper = makeHelper()
        let audioTrack = TestData.trackInfo(sid: "TR_mic", name: "mic", type: .audio, source: .microphone)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [audioTrack])

        XCTAssertNotNil(participant.firstAudioPublication)
        XCTAssertEqual(participant.firstAudioPublication?.sid, Track.Sid(from: "TR_mic"))
    }

    func testFirstAudioPublicationWithNoAudioTracks() {
        let helper = makeHelper()
        let videoTrack = TestData.trackInfo(sid: "TR_cam", name: "camera", type: .video, source: .camera)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [videoTrack])

        XCTAssertNil(participant.firstAudioPublication)
    }

    // MARK: - firstTrackEncryptionType

    func testFirstTrackEncryptionTypeWithNoTracks() {
        let helper = makeHelper()
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [])

        XCTAssertEqual(participant.firstTrackEncryptionType, .none)
    }

    func testFirstTrackEncryptionTypeFallsThroughSources() {
        let helper = makeHelper()
        // Only audio track — fallthrough from camera → screenShare → audio
        let audioTrack = TestData.trackInfo(sid: "TR_mic", name: "mic", type: .audio, source: .microphone)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [audioTrack])

        // Default encryption is .none
        XCTAssertEqual(participant.firstTrackEncryptionType, .none)
    }

    // MARK: - firstCameraVideoTrack / firstScreenShareVideoTrack / firstAudioTrack

    func testFirstCameraVideoTrackNilWhenNoTrackAttached() {
        let helper = makeHelper()
        let cameraTrack = TestData.trackInfo(sid: "TR_cam", name: "camera", type: .video, source: .camera)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [cameraTrack])

        // Publication exists but no real track is attached, so returns nil
        XCTAssertNil(participant.firstCameraVideoTrack)
    }

    func testFirstScreenShareVideoTrackNilWhenNoTrackAttached() {
        let helper = makeHelper()
        let screenTrack = TestData.trackInfo(sid: "TR_screen", name: "screen", type: .video, source: .screenShare)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [screenTrack])

        XCTAssertNil(participant.firstScreenShareVideoTrack)
    }

    func testFirstAudioTrackNilWhenNoTrackAttached() {
        let helper = makeHelper()
        let audioTrack = TestData.trackInfo(sid: "TR_mic", name: "mic", type: .audio, source: .microphone)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [audioTrack])

        XCTAssertNil(participant.firstAudioTrack)
    }

    // MARK: - Multiple tracks

    func testMultiplePublicationsSelectCorrectSource() {
        let helper = makeHelper()
        let camera = TestData.trackInfo(sid: "TR_cam", name: "camera", type: .video, source: .camera)
        let screen = TestData.trackInfo(sid: "TR_screen", name: "screen", type: .video, source: .screenShare)
        let audio = TestData.trackInfo(sid: "TR_mic", name: "mic", type: .audio, source: .microphone)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [camera, screen, audio])

        XCTAssertEqual(participant.firstCameraPublication?.sid, Track.Sid(from: "TR_cam"))
        XCTAssertEqual(participant.firstScreenSharePublication?.sid, Track.Sid(from: "TR_screen"))
        XCTAssertEqual(participant.firstAudioPublication?.sid, Track.Sid(from: "TR_mic"))
    }

    // MARK: - Participant+Agent: isAgent

    func testIsAgentTrueForAgentKind() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1", name: "Agent",
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        XCTAssertTrue(participant.isAgent)
    }

    func testIsAgentFalseForStandardKind() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_std", identity: "user-1", name: "User",
            kind: .standard
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        XCTAssertFalse(participant.isAgent)
    }

    func testIsAgentFalseForUnknownKind() {
        let helper = makeHelper()
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1")

        // Default kind from TestData is .standard
        XCTAssertFalse(participant.isAgent)
    }

    // MARK: - Participant+Agent: agentState

    func testAgentStateDefaultsToIdle() {
        let helper = makeHelper()
        let info = TestData.participantInfo(sid: "PA_agent", identity: "agent-1", kind: .agent)
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        // No agent attributes set — defaults to .idle
        XCTAssertEqual(participant.agentState, .idle)
    }

    func testAgentStateFromAttributes() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "listening"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        XCTAssertEqual(participant.agentState, .listening)
    }

    func testAgentStateSpeaking() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "speaking"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        XCTAssertEqual(participant.agentState, .speaking)
    }

    func testAgentStateThinking() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "thinking"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        XCTAssertEqual(participant.agentState, .thinking)
    }

    // MARK: - Participant+Agent: agentStateString

    func testAgentStateStringMatchesRawValue() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "speaking"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        XCTAssertEqual(participant.agentStateString, "speaking")
    }

    // MARK: - AgentState description

    func testAgentStateDescription() {
        XCTAssertEqual(AgentState.idle.description, "Idle")
        XCTAssertEqual(AgentState.listening.description, "Listening")
        XCTAssertEqual(AgentState.thinking.description, "Thinking")
        XCTAssertEqual(AgentState.speaking.description, "Speaking")
        XCTAssertEqual(AgentState.initializing.description, "Initializing")
    }

    // MARK: - Participant.Kind description

    func testParticipantKindDescriptions() {
        XCTAssertEqual(Participant.Kind.unknown.description, "unknown")
        XCTAssertEqual(Participant.Kind.standard.description, "standard")
        XCTAssertEqual(Participant.Kind.ingress.description, "ingress")
        XCTAssertEqual(Participant.Kind.egress.description, "egress")
        XCTAssertEqual(Participant.Kind.sip.description, "sip")
        XCTAssertEqual(Participant.Kind.agent.description, "agent")
    }

    // MARK: - Participant+Agent: avatarWorker

    func testAvatarWorkerNilWhenNoPublishingOnBehalf() {
        let helper = makeHelper()
        let info = TestData.participantInfo(sid: "PA_agent", identity: "agent-1", kind: .agent)
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)
        helper.room._state.mutate {
            $0.remoteParticipants[Participant.Identity(from: "agent-1")] = participant
        }

        XCTAssertNil(participant.avatarWorker)
    }
}
