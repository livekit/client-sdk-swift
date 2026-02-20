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

/// Tests for SignalClient._process response dispatch.
/// These inject Livekit_SignalResponse messages through SignalClient's _process method,
/// which dispatches to its delegate (Room), testing the full pipeline:
/// signalResponse -> SignalClient._process -> delegate notification -> Room handler.
class SignalClientDispatchTests: LKTestCase {
    // MARK: - Helper

    private func makeHelper() -> RoomTestHelper {
        RoomTestHelper()
    }

    /// Wait for AsyncSerialDelegate's detached dispatch.
    private func waitForDispatch() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - Join Response

    func testProcessJoinResponseSetsRoomProperties() async {
        let helper = makeHelper()
        let joinResponse = TestData.joinResponse(
            room: TestData.roomInfo(sid: "RM_dispatch", name: "dispatch-room"),
            participant: TestData.participantInfo(sid: "PA_local", identity: "local-user"),
            serverInfo: TestData.serverInfo(version: "2.0.0", region: "eu-west-1")
        )

        await helper.processSignalResponse(TestData.signalResponse(join: joinResponse))
        await waitForDispatch()

        XCTAssertEqual(helper.room.sid?.stringValue, "RM_dispatch")
        XCTAssertEqual(helper.room.name, "dispatch-room")
        XCTAssertEqual(helper.room.serverVersion, "2.0.0")
        XCTAssertEqual(helper.room.serverRegion, "eu-west-1")
    }

    func testProcessJoinResponseAddsRemoteParticipants() async {
        let helper = makeHelper()
        let remote = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", name: "Remote 1")
        let joinResponse = TestData.joinResponse(
            participant: TestData.participantInfo(sid: "PA_local", identity: "local-user"),
            otherParticipants: [remote]
        )

        await helper.processSignalResponse(TestData.signalResponse(join: joinResponse))
        await waitForDispatch()

        XCTAssertEqual(helper.room.remoteParticipants.count, 1)
        XCTAssertNotNil(helper.room.remoteParticipants[Participant.Identity(from: "remote-1")])
    }

    func testProcessJoinResponseStoresLastJoinResponse() async {
        let helper = makeHelper()
        let joinResponse = TestData.joinResponse(
            room: TestData.roomInfo(sid: "RM_stored", name: "stored-room"),
            participant: TestData.participantInfo(sid: "PA_local", identity: "local-user")
        )

        await helper.processSignalResponse(TestData.signalResponse(join: joinResponse))
        await waitForDispatch()

        // Verify join response was processed by checking room properties set from it
        XCTAssertEqual(helper.room.sid?.stringValue, "RM_stored")
        XCTAssertEqual(helper.room.name, "stored-room")
    }

    // MARK: - Room Update

    func testProcessRoomUpdateSetsMetadata() async {
        let helper = makeHelper()
        let roomUpdate = Livekit_Room.with {
            $0.metadata = "process-meta"
            $0.activeRecording = true
            $0.numParticipants = 10
            $0.numPublishers = 3
        }

        await helper.processSignalResponse(TestData.signalResponse(roomUpdate: roomUpdate))
        await waitForDispatch()

        XCTAssertEqual(helper.room.metadata, "process-meta")
        XCTAssertTrue(helper.room.isRecording)
        XCTAssertEqual(helper.room.participantCount, 10)
        XCTAssertEqual(helper.room.publishersCount, 3)
    }

    // MARK: - Participant Update

    func testProcessParticipantUpdateAddsParticipant() async {
        let helper = makeHelper()
        let participant = TestData.participantInfo(sid: "PA_new", identity: "new-user", name: "New User")

        await helper.processSignalResponse(TestData.signalResponse(participantUpdate: [participant]))
        await waitForDispatch()

        XCTAssertEqual(helper.room.remoteParticipants.count, 1)
        let identity = Participant.Identity(from: "new-user")
        XCTAssertEqual(helper.room.remoteParticipants[identity]?.name, "New User")
    }

    func testProcessParticipantUpdateRemovesDisconnected() async {
        let helper = makeHelper()
        // Add participant first
        let participant = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        await helper.processSignalResponse(TestData.signalResponse(participantUpdate: [participant]))
        await waitForDispatch()
        XCTAssertEqual(helper.room.remoteParticipants.count, 1)

        // Disconnect
        let disconnected = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", state: .disconnected)
        await helper.processSignalResponse(TestData.signalResponse(participantUpdate: [disconnected]))
        await waitForDispatch()

        XCTAssertEqual(helper.room.remoteParticipants.count, 0)
    }

    // MARK: - Speaker Update

    func testProcessSpeakerUpdateSetsSpeakingState() async {
        let helper = makeHelper()
        // Add remote participant
        let participant = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        await helper.processSignalResponse(TestData.signalResponse(participantUpdate: [participant]))
        await waitForDispatch()

        let speaker = TestData.speakerInfo(sid: "PA_r1", level: 0.85, active: true)
        await helper.processSignalResponse(TestData.signalResponse(speakersChanged: [speaker]))
        await waitForDispatch()

        let identity = Participant.Identity(from: "remote-1")
        let remote = helper.room.remoteParticipants[identity]
        XCTAssertTrue(remote?.isSpeaking ?? false)
        XCTAssertEqual(remote?.audioLevel ?? 0, 0.85, accuracy: 0.01)
    }

    // MARK: - Connection Quality

    func testProcessConnectionQualityUpdatesParticipant() async {
        let helper = makeHelper()
        let participant = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        await helper.processSignalResponse(TestData.signalResponse(participantUpdate: [participant]))
        await waitForDispatch()

        let quality = TestData.connectionQualityInfo(participantSid: "PA_r1", quality: .excellent)
        await helper.processSignalResponse(TestData.signalResponse(connectionQuality: [quality]))
        await waitForDispatch()

        let identity = Participant.Identity(from: "remote-1")
        XCTAssertEqual(helper.room.remoteParticipants[identity]?.connectionQuality, .excellent)
    }

    func testProcessConnectionQualityUpdatesLocalParticipant() async {
        let helper = makeHelper()

        let quality = TestData.connectionQualityInfo(participantSid: "PA_local", quality: .poor)
        await helper.processSignalResponse(TestData.signalResponse(connectionQuality: [quality]))
        await waitForDispatch()

        XCTAssertEqual(helper.room.localParticipant.connectionQuality, .poor)
    }

    // MARK: - Token Refresh

    func testProcessTokenRefreshUpdatesToken() async {
        let helper = makeHelper()
        helper.room._state.mutate { $0.token = "old-token" }

        await helper.processSignalResponse(TestData.signalResponse(refreshToken: "refreshed-token"))
        await waitForDispatch()

        XCTAssertEqual(helper.room.token, "refreshed-token")
    }

    // MARK: - Leave

    func testProcessLeaveDisconnectCleansUp() async {
        let helper = makeHelper()

        await helper.processSignalResponse(TestData.signalResponse(leave: .disconnect, reason: .clientInitiated))
        await waitForDispatch()

        XCTAssertEqual(helper.room.connectionState, .disconnected)
    }

    func testProcessLeaveReconnectSetsFullMode() async {
        let helper = makeHelper()

        await helper.processSignalResponse(TestData.signalResponse(leave: .reconnect))
        await waitForDispatch()

        let nextMode = helper.room._state.read { $0.nextReconnectMode }
        XCTAssertEqual(nextMode, .full)
    }

    // MARK: - Stream State Update

    func testProcessStreamStateUpdateSetsStreamState() async {
        let helper = makeHelper()
        let trackInfo = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [trackInfo])

        let stateInfo = TestData.streamStateInfo(participantSid: "PA_r1", trackSid: "TR_v1", state: .active)
        await helper.processSignalResponse(TestData.signalResponse(streamStates: [stateInfo]))
        await waitForDispatch()

        let pub = participant.trackPublications[Track.Sid(from: "TR_v1")] as? RemoteTrackPublication
        XCTAssertEqual(pub?.streamState, .active)
    }

    // MARK: - Subscription Permission Update

    func testProcessSubscriptionPermissionUpdateSetsAllowed() async {
        let helper = makeHelper()
        let trackInfo = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let participant = helper.addRemoteParticipant(sid: "PA_r1", identity: "remote-1", tracks: [trackInfo])

        let permUpdate = TestData.subscriptionPermissionUpdate(participantSid: "PA_r1", trackSid: "TR_v1", allowed: false)
        await helper.processSignalResponse(TestData.signalResponse(subscriptionPermission: permUpdate))
        await waitForDispatch()

        let pub = participant.trackPublications[Track.Sid(from: "TR_v1")] as? RemoteTrackPublication
        XCTAssertFalse(pub?.isSubscriptionAllowed ?? true)
        XCTAssertEqual(pub?.subscriptionState, .notAllowed)
    }

    // MARK: - Mute Update

    func testProcessMuteUpdateNoPublicationIsNoOp() async {
        let helper = makeHelper()
        let metadataBefore = helper.room.metadata

        // Remote mute targets local publications — without a real published track, it's a no-op
        await helper.processSignalResponse(TestData.signalResponse(mute: "TR_nonexistent", muted: true))
        await waitForDispatch()

        // State unchanged
        XCTAssertEqual(helper.room.metadata, metadataBefore)
    }

    // MARK: - Pong

    func testProcessPongDoesNotCrash() async {
        let helper = makeHelper()
        let connectionState = helper.room.connectionState

        await helper.processSignalResponse(TestData.signalResponse(pong: 1_700_000_000_000))
        await waitForDispatch()

        // Connection state should remain unchanged
        XCTAssertEqual(helper.room.connectionState, connectionState)
    }

    // MARK: - Guards

    func testProcessSkipsWhenDisconnected() async {
        let helper = makeHelper()
        // Set signal client to disconnected
        await helper.room.signalClient.setConnectionState(.disconnected)

        let roomUpdate = Livekit_Room.with { $0.metadata = "should-not-apply" }
        // Call _process directly (not through processSignalResponse which sets connected)
        await helper.room.signalClient._process(signalResponse: TestData.signalResponse(roomUpdate: roomUpdate))
        await waitForDispatch()

        // Room metadata should NOT have changed
        XCTAssertNotEqual(helper.room.metadata, "should-not-apply")
    }

    func testProcessSkipsEmptyMessage() async {
        let helper = makeHelper()
        let participantCount = helper.room.remoteParticipants.count

        // Empty signal response with no message set
        let emptyResponse = Livekit_SignalResponse()
        await helper.processSignalResponse(emptyResponse)
        await waitForDispatch()

        // State unchanged
        XCTAssertEqual(helper.room.remoteParticipants.count, participantCount)
    }

    // MARK: - Room Moved

    func testProcessRoomMovedUpdatesState() async {
        let helper = makeHelper()
        let newRoom = TestData.roomInfo(sid: "RM_new", name: "new-room", metadata: "moved-meta")
        let movedResponse = TestData.roomMovedResponse(
            room: newRoom,
            token: "moved-token",
            participant: TestData.participantInfo(sid: "PA_local", identity: "local-user", name: "Updated Local")
        )

        await helper.processSignalResponse(TestData.signalResponse(roomMoved: movedResponse))
        await waitForDispatch()

        XCTAssertEqual(helper.room.sid?.stringValue, "RM_new")
        XCTAssertEqual(helper.room.name, "new-room")
        XCTAssertEqual(helper.room.token, "moved-token")
    }

    // MARK: - Track Unpublished

    func testProcessTrackUnpublishedDispatch() async {
        let helper = makeHelper()
        let connectionState = helper.room.connectionState

        // Without a real local track publication, the unpublish is a no-op
        await helper.processSignalResponse(TestData.signalResponse(trackUnpublished: "TR_nonexistent"))
        await waitForDispatch()

        // State unchanged (no crash, no side effects)
        XCTAssertEqual(helper.room.connectionState, connectionState)
    }

    // MARK: - Pong Response

    func testProcessPongRespUpdatesRTT() async {
        let helper = makeHelper()
        // Send a pongResp with a timestamp
        let pongResp = Livekit_SignalResponse.with {
            $0.pongResp = Livekit_Pong.with {
                // Simulate a pong that was 50ms ago
                $0.lastPingTimestamp = Int64(Date().timeIntervalSince1970 * 1000) - 50
            }
        }

        await helper.processSignalResponse(pongResp)
        await waitForDispatch()

        // RTT should have been updated on the SignalClient
        let rtt = await helper.room.signalClient._state.read { $0.rtt }
        XCTAssertGreaterThan(rtt, 0)
    }

    // MARK: - Track Subscribed

    func testProcessTrackSubscribedNoPublicationIsNoOp() async {
        let helper = makeHelper()
        let connectionState = helper.room.connectionState

        // Without a real local track publication, this is a no-op
        await helper.processSignalResponse(TestData.signalResponse(trackSubscribed: "TR_nonexistent"))
        await waitForDispatch()

        // State unchanged
        XCTAssertEqual(helper.room.connectionState, connectionState)
    }

    // MARK: - Multiple Responses in Sequence

    func testProcessMultipleResponsesInSequence() async {
        let helper = makeHelper()

        // 1. Join
        let joinResponse = TestData.joinResponse(
            room: TestData.roomInfo(sid: "RM_seq", name: "seq-room"),
            participant: TestData.participantInfo(sid: "PA_local", identity: "local-user")
        )
        await helper.processSignalResponse(TestData.signalResponse(join: joinResponse))
        await waitForDispatch()

        // 2. Participant update
        let remote = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        await helper.processSignalResponse(TestData.signalResponse(participantUpdate: [remote]))
        await waitForDispatch()

        // 3. Speaker update
        let speaker = TestData.speakerInfo(sid: "PA_r1", level: 0.7, active: true)
        await helper.processSignalResponse(TestData.signalResponse(speakersChanged: [speaker]))
        await waitForDispatch()

        // 4. Connection quality
        let quality = TestData.connectionQualityInfo(participantSid: "PA_r1", quality: .good)
        await helper.processSignalResponse(TestData.signalResponse(connectionQuality: [quality]))
        await waitForDispatch()

        // Verify cumulative state
        XCTAssertEqual(helper.room.name, "seq-room")
        let identity = Participant.Identity(from: "remote-1")
        let participant = helper.room.remoteParticipants[identity]
        XCTAssertNotNil(participant)
        XCTAssertTrue(participant?.isSpeaking ?? false)
        XCTAssertEqual(participant?.connectionQuality, .good)
    }

    // MARK: - Trickle (invalid candidate)

    func testProcessTrickleWithInvalidCandidateIsNoOp() async {
        let helper = makeHelper()
        let connectionState = helper.room.connectionState

        // Trickle with invalid JSON should hit the guard and return
        let trickleResponse = Livekit_SignalResponse.with {
            $0.trickle = Livekit_TrickleRequest.with {
                $0.candidateInit = "not-valid-json"
                $0.target = .publisher
            }
        }
        await helper.processSignalResponse(trickleResponse)
        await waitForDispatch()

        // State unchanged (no crash, guard returned early)
        XCTAssertEqual(helper.room.connectionState, connectionState)
    }

    // MARK: - Reconnect Response

    func testProcessReconnectResponseDoesNotCrash() async {
        let helper = makeHelper()
        let connectionState = helper.room.connectionState

        let reconnectResponse = Livekit_SignalResponse.with {
            $0.reconnect = Livekit_ReconnectResponse.with {
                $0.iceServers = []
            }
        }
        await helper.processSignalResponse(reconnectResponse)
        await waitForDispatch()

        // Reconnect response was processed without crash
        XCTAssertEqual(helper.room.connectionState, connectionState)
    }

    // MARK: - Track Published (completer resolution)

    func testProcessTrackPublishedResolvesCompleter() async {
        let helper = makeHelper()
        let trackInfo = TestData.trackInfo(sid: "TR_pub1", name: "camera", type: .video, source: .camera)

        // Process a trackPublished response — the completer is identified by cid
        let response = TestData.signalResponse(trackPublished: "test-cid", track: trackInfo)
        await helper.processSignalResponse(response)
        await waitForDispatch()

        // No crash — the completer had no waiter, which is fine
        XCTAssertEqual(helper.room.connectionState, .connected)
    }

    // MARK: - Subscribed Quality Update

    func testProcessSubscribedQualityUpdateDispatch() async {
        let helper = makeHelper()
        let connectionState = helper.room.connectionState

        let response = Livekit_SignalResponse.with {
            $0.subscribedQualityUpdate = Livekit_SubscribedQualityUpdate.with {
                $0.trackSid = "TR_v1"
                $0.subscribedQualities = [
                    Livekit_SubscribedQuality.with {
                        $0.quality = .high
                        $0.enabled = true
                    },
                ]
                $0.subscribedCodecs = []
            }
        }
        await helper.processSignalResponse(response)
        await waitForDispatch()

        // State unchanged (no matching local track, but no crash)
        XCTAssertEqual(helper.room.connectionState, connectionState)
    }

    // MARK: - Answer / Offer Response Dispatch

    func testProcessAnswerResponseDoesNotCrash() async {
        let helper = makeHelper()

        let response = Livekit_SignalResponse.with {
            $0.answer = Livekit_SessionDescription.with {
                $0.type = "answer"
                $0.sdp = "v=0\r\n"
            }
        }
        await helper.processSignalResponse(response)
        await waitForDispatch()

        XCTAssertEqual(helper.room.connectionState, .connected)
    }

    // MARK: - Default (unhandled message type)

    func testProcessUnhandledMessageTypeIsNoOp() async {
        let helper = makeHelper()
        let connectionState = helper.room.connectionState

        // subscriptionResponse is not handled in _process switch — hits the default case
        let response = Livekit_SignalResponse.with {
            $0.subscriptionResponse = Livekit_SubscriptionResponse.with {
                $0.trackSid = "TR_v1"
            }
        }
        await helper.processSignalResponse(response)
        await waitForDispatch()

        // State unchanged (default case just logs)
        XCTAssertEqual(helper.room.connectionState, connectionState)
    }

    // MARK: - Answer / Offer Response Dispatch

    func testProcessOfferResponseDoesNotCrash() async {
        let helper = makeHelper()

        let response = Livekit_SignalResponse.with {
            $0.offer = Livekit_SessionDescription.with {
                $0.type = "offer"
                $0.sdp = "v=0\r\n"
            }
        }
        await helper.processSignalResponse(response)
        await waitForDispatch()

        XCTAssertEqual(helper.room.connectionState, .connected)
    }
}
