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

/// Tests for SignalClient send methods using MockWebSocket.
/// Verifies that each send method produces the correct protobuf message.
class SignalClientSendTests: LKTestCase {
    private var signalClient: SignalClient!
    private var mockSocket: MockWebSocket!

    override func setUp() async throws {
        try await super.setUp()
        signalClient = SignalClient()
        mockSocket = MockWebSocket()
        await signalClient.setWebSocket(mockSocket)
        await signalClient.setConnectionState(.connected)
        await signalClient.resumeQueues()
    }

    /// Wait for the request queue to process.
    private func waitForQueue() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - sendMuteTrack

    func testSendMuteTrackProducesCorrectRequest() async throws {
        try await signalClient.sendMuteTrack(trackSid: Track.Sid(from: "TR_audio1"), muted: true)
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .mute = request.message else {
            return XCTFail("Expected .mute message, got \(String(describing: request.message))")
        }
        XCTAssertEqual(request.mute.sid, "TR_audio1")
        XCTAssertTrue(request.mute.muted)
    }

    func testSendMuteTrackUnmute() async throws {
        try await signalClient.sendMuteTrack(trackSid: Track.Sid(from: "TR_audio1"), muted: false)
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        XCTAssertFalse(mockSocket.sentRequests[0].mute.muted)
    }

    // MARK: - sendUpdateTrackSettings

    func testSendUpdateTrackSettings() async throws {
        let settings = TrackSettings(
            enabled: true,
            dimensions: Dimensions(width: 1280, height: 720),
            videoQuality: .high,
            preferredFPS: 30
        )

        try await signalClient.sendUpdateTrackSettings(trackSid: Track.Sid(from: "TR_video1"), settings: settings)
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .trackSetting = request.message else {
            return XCTFail("Expected .trackSetting message")
        }
        XCTAssertEqual(request.trackSetting.trackSids, ["TR_video1"])
        XCTAssertFalse(request.trackSetting.disabled) // isEnabled = true → disabled = false
        XCTAssertEqual(request.trackSetting.width, 1280)
        XCTAssertEqual(request.trackSetting.height, 720)
        XCTAssertEqual(request.trackSetting.fps, 30)
    }

    func testSendUpdateTrackSettingsDisabled() async throws {
        let settings = TrackSettings(
            enabled: false,
            dimensions: .zero,
            videoQuality: .low,
            preferredFPS: 0
        )

        try await signalClient.sendUpdateTrackSettings(trackSid: Track.Sid(from: "TR_video1"), settings: settings)
        await waitForQueue()

        let request = mockSocket.sentRequests[0]
        XCTAssertTrue(request.trackSetting.disabled)
    }

    // MARK: - sendUpdateVideoLayers

    func testSendUpdateVideoLayers() async throws {
        let layers = [
            Livekit_VideoLayer.with {
                $0.quality = .high
                $0.width = 1920
                $0.height = 1080
            },
            Livekit_VideoLayer.with {
                $0.quality = .low
                $0.width = 480
                $0.height = 270
            },
        ]

        try await signalClient.sendUpdateVideoLayers(trackSid: Track.Sid(from: "TR_v1"), layers: layers)
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .updateLayers = request.message else {
            return XCTFail("Expected .updateLayers message")
        }
        XCTAssertEqual(request.updateLayers.trackSid, "TR_v1")
        XCTAssertEqual(request.updateLayers.layers.count, 2)
        XCTAssertEqual(request.updateLayers.layers[0].quality, .high)
        XCTAssertEqual(request.updateLayers.layers[1].width, 480)
    }

    // MARK: - sendUpdateSubscription

    func testSendUpdateSubscription() async throws {
        try await signalClient.sendUpdateSubscription(
            participantSid: Participant.Sid(from: "PA_r1"),
            trackSid: Track.Sid(from: "TR_v1"),
            isSubscribed: true
        )
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .subscription = request.message else {
            return XCTFail("Expected .subscription message")
        }
        XCTAssertTrue(request.subscription.subscribe)
        XCTAssertEqual(request.subscription.trackSids, ["TR_v1"])
        XCTAssertEqual(request.subscription.participantTracks.count, 1)
        XCTAssertEqual(request.subscription.participantTracks[0].participantSid, "PA_r1")
    }

    func testSendUpdateSubscriptionUnsubscribe() async throws {
        try await signalClient.sendUpdateSubscription(
            participantSid: Participant.Sid(from: "PA_r1"),
            trackSid: Track.Sid(from: "TR_v1"),
            isSubscribed: false
        )
        await waitForQueue()

        XCTAssertFalse(mockSocket.sentRequests[0].subscription.subscribe)
    }

    // MARK: - sendUpdateParticipant

    func testSendUpdateParticipantMetadata() async throws {
        try await signalClient.sendUpdateParticipant(
            name: "New Name",
            metadata: "{\"role\":\"admin\"}",
            attributes: ["team": "engineering"]
        )
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .updateMetadata = request.message else {
            return XCTFail("Expected .updateMetadata message")
        }
        XCTAssertEqual(request.updateMetadata.name, "New Name")
        XCTAssertEqual(request.updateMetadata.metadata, "{\"role\":\"admin\"}")
        XCTAssertEqual(request.updateMetadata.attributes["team"], "engineering")
    }

    func testSendUpdateParticipantNilValues() async throws {
        try await signalClient.sendUpdateParticipant(name: nil, metadata: nil, attributes: nil)
        await waitForQueue()

        let request = mockSocket.sentRequests[0]
        XCTAssertEqual(request.updateMetadata.name, "")
        XCTAssertEqual(request.updateMetadata.metadata, "")
        XCTAssertTrue(request.updateMetadata.attributes.isEmpty)
    }

    // MARK: - sendUpdateSubscriptionPermission

    func testSendUpdateSubscriptionPermissionEmpty() async throws {
        try await signalClient.sendUpdateSubscriptionPermission(
            allParticipants: false,
            trackPermissions: []
        )
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .subscriptionPermission = request.message else {
            return XCTFail("Expected .subscriptionPermission message")
        }
        XCTAssertFalse(request.subscriptionPermission.allParticipants)
    }

    func testSendUpdateSubscriptionPermissionWithTracks() async throws {
        let permissions = [
            ParticipantTrackPermission(
                participantSid: "PA_r1",
                allTracksAllowed: false,
                allowedTrackSids: ["TR_v1", "TR_a1"]
            ),
        ]

        try await signalClient.sendUpdateSubscriptionPermission(
            allParticipants: false,
            trackPermissions: permissions
        )
        await waitForQueue()

        let request = mockSocket.sentRequests[0]
        XCTAssertEqual(request.subscriptionPermission.trackPermissions.count, 1)
        XCTAssertEqual(request.subscriptionPermission.trackPermissions[0].participantSid, "PA_r1")
        XCTAssertFalse(request.subscriptionPermission.trackPermissions[0].allTracks)
        XCTAssertEqual(request.subscriptionPermission.trackPermissions[0].trackSids, ["TR_v1", "TR_a1"])
    }

    // MARK: - sendUpdateLocalAudioTrack

    func testSendUpdateLocalAudioTrack() async throws {
        try await signalClient.sendUpdateLocalAudioTrack(
            trackSid: Track.Sid(from: "TR_mic1"),
            features: [.tfEnhancedNoiseCancellation]
        )
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .updateAudioTrack = request.message else {
            return XCTFail("Expected .updateAudioTrack message")
        }
        XCTAssertEqual(request.updateAudioTrack.trackSid, "TR_mic1")
        XCTAssertEqual(request.updateAudioTrack.features.count, 1)
    }

    // MARK: - sendLeave

    func testSendLeave() async throws {
        try await signalClient.sendLeave()
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .leave = request.message else {
            return XCTFail("Expected .leave message")
        }
        XCTAssertFalse(request.leave.canReconnect)
        XCTAssertEqual(request.leave.reason, .clientInitiated)
    }

    // MARK: - sendSyncState

    func testSendSyncState() async throws {
        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = ["TR_v1", "TR_a1"]
            $0.subscribe = true
        }

        try await signalClient.sendSyncState(
            answer: nil,
            offer: nil,
            subscription: subscription,
            publishTracks: [],
            dataChannels: [],
            dataChannelReceiveStates: []
        )
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .syncState = request.message else {
            return XCTFail("Expected .syncState message")
        }
        XCTAssertEqual(request.syncState.subscription.trackSids, ["TR_v1", "TR_a1"])
        XCTAssertTrue(request.syncState.subscription.subscribe)
    }

    func testSendSyncStateWithAnswer() async throws {
        let answer = Livekit_SessionDescription.with {
            $0.type = "answer"
            $0.sdp = "v=0\r\n..."
        }

        try await signalClient.sendSyncState(
            answer: answer,
            offer: nil,
            subscription: Livekit_UpdateSubscription()
        )
        await waitForQueue()

        let request = mockSocket.sentRequests[0]
        XCTAssertTrue(request.syncState.hasAnswer)
        XCTAssertEqual(request.syncState.answer.type, "answer")
    }

    // MARK: - sendSimulate

    func testSendSimulateNodeFailure() async throws {
        try await signalClient.sendSimulate(scenario: .nodeFailure)
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        guard case .simulate = request.message else {
            return XCTFail("Expected .simulate message")
        }
        XCTAssertTrue(request.simulate.nodeFailure)
    }

    func testSendSimulateMigration() async throws {
        try await signalClient.sendSimulate(scenario: .migration)
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        guard case .simulate = mockSocket.sentRequests[0].message else {
            return XCTFail("Expected .simulate message")
        }
        XCTAssertTrue(mockSocket.sentRequests[0].simulate.migration)
    }

    func testSendSimulateServerLeave() async throws {
        try await signalClient.sendSimulate(scenario: .serverLeave)
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        guard case .simulate = mockSocket.sentRequests[0].message else {
            return XCTFail("Expected .simulate message")
        }
        XCTAssertTrue(mockSocket.sentRequests[0].simulate.serverLeave)
    }

    func testSendSimulateSpeakerUpdate() async throws {
        try await signalClient.sendSimulate(scenario: .speakerUpdate(seconds: 5))
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        guard case .simulate = mockSocket.sentRequests[0].message else {
            return XCTFail("Expected .simulate message")
        }
        XCTAssertEqual(mockSocket.sentRequests[0].simulate.speakerUpdate, 5)
    }

    func testSendSimulateForceTCPTriggersCleanup() async throws {
        try await signalClient.sendSimulate(scenario: .forceTCP)
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        XCTAssertEqual(request.simulate.switchCandidateProtocol, .tcp)

        // Wait for the deferred Task.detached cleanUp to fire
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(mockSocket.isClosed)
    }

    func testSendSimulateForceTLSTriggersCleanup() async throws {
        try await signalClient.sendSimulate(scenario: .forceTLS)
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 1)
        let request = mockSocket.sentRequests[0]
        XCTAssertEqual(request.simulate.switchCandidateProtocol, .tls)

        // Wait for the deferred Task.detached cleanUp to fire
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(mockSocket.isClosed)
    }

    // MARK: - requireWebSocket nil path

    func testSendWithoutSocketThrowsViaQueue() async throws {
        // Create a fresh signal client without setting a socket
        let freshClient = SignalClient()
        await freshClient.setConnectionState(.connected)
        await freshClient.resumeQueues()

        // The queue's onProcess will call requireWebSocket which should throw
        // The error is caught and logged internally — this verifies it doesn't crash
        try await freshClient.sendMuteTrack(trackSid: Track.Sid(from: "TR_1"), muted: true)
        await waitForQueue()

        // Nothing should have been sent (no socket)
        XCTAssertEqual(mockSocket.sentRequests.count, 0)
    }

    // MARK: - connect() error paths

    func testConnectWithFactoryError() async {
        let client = SignalClient()
        await client.setWebSocketFactory { _, _, _ in
            throw LiveKitError(.network, message: "Connection refused")
        }

        do {
            try await client.connect(
                URL(string: "wss://example.com")!,
                "test-token",
                adaptiveStream: false
            )
            XCTFail("Should have thrown")
        } catch {
            // Verify it was cleaned up properly
            let state = await client.connectionState
            XCTAssertEqual(state, .disconnected)
        }
    }

    func testConnectSetsReconnectingState() async {
        let client = SignalClient()
        await client.setWebSocketFactory { _, _, _ in
            throw LiveKitError(.network, message: "Reconnect failed")
        }

        do {
            try await client.connect(
                URL(string: "wss://example.com")!,
                "test-token",
                reconnectMode: .quick,
                adaptiveStream: false
            )
            XCTFail("Should have thrown")
        } catch {
            // After failure, should be disconnected
            let state = await client.connectionState
            XCTAssertEqual(state, .disconnected)
            XCTAssertTrue(error is LiveKitError)
        }
    }

    // MARK: - Error Handling

    func testSendWhenDisconnectedThrows() async {
        await signalClient.setConnectionState(.disconnected)

        do {
            try await signalClient.sendMuteTrack(trackSid: Track.Sid(from: "TR_1"), muted: true)
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is LiveKitError)
        }
    }

    func testSendWithSocketErrorDoesNotCrash() async throws {
        mockSocket.setSendError(LiveKitError(.network, message: "Mock send failure"))

        // The request queue catches send errors internally (logged as warning).
        // This verifies the error path doesn't crash.
        try await signalClient.sendMuteTrack(trackSid: Track.Sid(from: "TR_1"), muted: true)
        await waitForQueue()

        // The mock doesn't store data on error, so sentData should be empty
        XCTAssertEqual(mockSocket.sentData.count, 0)
    }

    // MARK: - canBeQueued

    func testCanBeQueuedForQueueableRequests() {
        let mute = Livekit_SignalRequest.with { $0.mute = Livekit_MuteTrackRequest() }
        XCTAssertTrue(mute.canBeQueued())

        let trackSetting = Livekit_SignalRequest.with { $0.trackSetting = Livekit_UpdateTrackSettings() }
        XCTAssertTrue(trackSetting.canBeQueued())

        let subscription = Livekit_SignalRequest.with { $0.subscription = Livekit_UpdateSubscription() }
        XCTAssertTrue(subscription.canBeQueued())
    }

    func testCanBeQueuedForNonQueueableRequests() {
        let syncState = Livekit_SignalRequest.with { $0.syncState = Livekit_SyncState() }
        XCTAssertFalse(syncState.canBeQueued())

        let trickle = Livekit_SignalRequest.with { $0.trickle = Livekit_TrickleRequest() }
        XCTAssertFalse(trickle.canBeQueued())

        let offer = Livekit_SignalRequest.with { $0.offer = Livekit_SessionDescription() }
        XCTAssertFalse(offer.canBeQueued())

        let answer = Livekit_SignalRequest.with { $0.answer = Livekit_SessionDescription() }
        XCTAssertFalse(answer.canBeQueued())

        let leave = Livekit_SignalRequest.with { $0.leave = Livekit_LeaveRequest() }
        XCTAssertFalse(leave.canBeQueued())

        let simulate = Livekit_SignalRequest.with { $0.simulate = Livekit_SimulateScenario() }
        XCTAssertFalse(simulate.canBeQueued())
    }

    // MARK: - Multiple Sends

    func testMultipleSendsAreCaptured() async throws {
        try await signalClient.sendMuteTrack(trackSid: Track.Sid(from: "TR_1"), muted: true)
        try await signalClient.sendMuteTrack(trackSid: Track.Sid(from: "TR_2"), muted: false)
        try await signalClient.sendLeave()
        await waitForQueue()

        XCTAssertEqual(mockSocket.sentRequests.count, 3)
        XCTAssertNotNil(mockSocket.sentRequests[0].message)
        XCTAssertNotNil(mockSocket.sentRequests[1].message)
        if case .mute = mockSocket.sentRequests[0].message {} else { XCTFail("Expected .mute") }
        if case .mute = mockSocket.sentRequests[1].message {} else { XCTFail("Expected .mute") }
        if case .leave = mockSocket.sentRequests[2].message {} else { XCTFail("Expected .leave") }
    }

    // MARK: - MockWebSocket Reset

    func testMockWebSocketReset() async throws {
        try await signalClient.sendLeave()
        await waitForQueue()
        XCTAssertEqual(mockSocket.sentRequests.count, 1)

        mockSocket.reset()
        XCTAssertEqual(mockSocket.sentRequests.count, 0)
        XCTAssertFalse(mockSocket.isClosed)
    }

    // MARK: - Close

    func testCleanUpClosesSocket() async {
        await signalClient.cleanUp()

        XCTAssertTrue(mockSocket.isClosed)
    }

    // MARK: - connect() CancellationError path

    func testConnectCancellationErrorPath() async {
        let client = SignalClient()
        await client.setWebSocketFactory { _, _, _ in
            throw CancellationError()
        }

        do {
            try await client.connect(
                URL(string: "wss://example.com")!,
                "test-token",
                adaptiveStream: false
            )
            XCTFail("Should have thrown")
        } catch {
            // CancellationError is re-thrown directly, not wrapped in LiveKitError
            XCTAssertTrue(error is CancellationError)
            let state = await client.connectionState
            XCTAssertEqual(state, .disconnected)
        }
    }

    // MARK: - connect() validation fallback path

    func testConnectValidationPathWhenHTTPFails() async {
        let client = SignalClient()
        await client.setWebSocketFactory { _, _, _ in
            throw LiveKitError(.network, message: "WebSocket refused")
        }

        do {
            // Non-reconnect mode: will try HTTP validation after WebSocket failure.
            // Uses 127.0.0.1 with a random port to ensure fast failure.
            try await client.connect(
                URL(string: "wss://127.0.0.1:1")!,
                "test-token",
                adaptiveStream: false
            )
            XCTFail("Should have thrown")
        } catch {
            // The error should be a LiveKitError wrapping the validation failure
            XCTAssertTrue(error is LiveKitError)
            let state = await client.connectionState
            XCTAssertEqual(state, .disconnected)
        }
    }

    // MARK: - WebSocket message decoding

    func testHandleWebSocketMessageWithStringJSON() async {
        // Create a signal response and encode as JSON string
        let response = Livekit_SignalResponse.with { $0.pong = 12345 }
        let jsonString = try! response.jsonString()

        // Process through the string message path
        await signalClient._testHandleWebSocketMessage(.string(jsonString))
        // Give the detached task time to process
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The pong should have been processed (cancels timeout timer)
        // No crash means the string path decoded successfully
    }

    func testHandleWebSocketMessageWithInvalidData() async {
        // Invalid data that can't be decoded as a SignalResponse
        let invalidData = Data([0xFF, 0xFE, 0x00, 0x01])
        await signalClient._testHandleWebSocketMessage(.data(invalidData))
        // Give time for processing
        try? await Task.sleep(nanoseconds: 100_000_000)

        // No crash — the guard should have caught the decode failure
    }

    func testHandleWebSocketMessageWithInvalidString() async {
        await signalClient._testHandleWebSocketMessage(.string("not valid json at all {{{"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // No crash — guard catches decode failure for string messages
    }

    // MARK: - Ping Timer Accessors

    func testPingTimerAccessors() async {
        // Simply accessing these verifies the test helper getters work
        let intervalTimer = await signalClient._testPingIntervalTimer
        let timeoutTimer = await signalClient._testPingTimeoutTimer
        XCTAssertNotNil(intervalTimer)
        XCTAssertNotNil(timeoutTimer)
    }

    // MARK: - sendPing

    func testSendPingProducesPingAndPingReq() async throws {
        // Set up a lastJoinResponse (required by _onPingIntervalTimer)
        await signalClient._state.mutate { $0.lastJoinResponse = TestData.joinResponse(pingInterval: 5, pingTimeout: 10) }

        try await signalClient._testSendPing()
        await waitForQueue()

        // _sendPing sends two requests: a .ping and a .pingReq
        XCTAssertEqual(mockSocket.sentRequests.count, 2)

        let firstRequest = mockSocket.sentRequests[0]
        guard case .ping = firstRequest.message else {
            return XCTFail("Expected .ping message, got \(String(describing: firstRequest.message))")
        }
        XCTAssertGreaterThan(firstRequest.ping, 0)

        let secondRequest = mockSocket.sentRequests[1]
        guard case .pingReq = secondRequest.message else {
            return XCTFail("Expected .pingReq message, got \(String(describing: secondRequest.message))")
        }
        XCTAssertGreaterThan(secondRequest.pingReq.timestamp, 0)
    }

    // MARK: - Ping timer fires after join response

    func testPingTimerFiresAfterJoinResponse() async throws {
        // Process a join response with a very short ping interval
        let joinResponse = TestData.joinResponse(pingInterval: 1, pingTimeout: 5)
        let joinSignal = Livekit_SignalResponse.with { $0.join = joinResponse }
        await signalClient._process(signalResponse: joinSignal)

        // Wait for the ping interval timer to fire (~1 second + buffer)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // The timer should have sent ping requests via the mock socket
        let pingRequests = mockSocket.sentRequests.filter {
            if case .ping = $0.message { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(pingRequests.count, 1, "Expected at least one ping to be sent")
    }

    // MARK: - Ping timeout triggers cleanup

    func testPingTimeoutTriggersCleanup() async throws {
        // Process a join response with very short ping interval AND timeout
        let joinResponse = TestData.joinResponse(pingInterval: 1, pingTimeout: 1)
        let joinSignal = Livekit_SignalResponse.with { $0.join = joinResponse }
        await signalClient._process(signalResponse: joinSignal)

        // Wait for ping interval (1s) + timeout (1s) + buffer
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // The timeout should have triggered cleanUp, setting state to disconnected
        let state = await signalClient.connectionState
        XCTAssertEqual(state, .disconnected)

        // The disconnect error should be serverPingTimedOut
        let error = await signalClient.disconnectError
        XCTAssertEqual(error?.type, .serverPingTimedOut)
    }

    // MARK: - sendSyncState with offer

    func testSendSyncStateWithOffer() async throws {
        let offer = Livekit_SessionDescription.with {
            $0.type = "offer"
            $0.sdp = "v=0\r\noffer-sdp"
        }

        try await signalClient.sendSyncState(
            answer: nil,
            offer: offer,
            subscription: Livekit_UpdateSubscription()
        )
        await waitForQueue()

        let request = mockSocket.sentRequests[0]
        XCTAssertTrue(request.syncState.hasOffer)
        XCTAssertEqual(request.syncState.offer.type, "offer")
    }

    func testSendSyncStateWithPublishTracksAndDataChannels() async throws {
        let publishTrack = Livekit_TrackPublishedResponse.with {
            $0.cid = "test-cid"
            $0.track = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        }
        let dataChannel = Livekit_DataChannelInfo.with {
            $0.label = "test-dc"
            $0.id = 1
            $0.target = .publisher
        }

        try await signalClient.sendSyncState(
            answer: nil,
            offer: nil,
            subscription: Livekit_UpdateSubscription(),
            publishTracks: [publishTrack],
            dataChannels: [dataChannel],
            dataChannelReceiveStates: []
        )
        await waitForQueue()

        let request = mockSocket.sentRequests[0]
        XCTAssertEqual(request.syncState.publishTracks.count, 1)
        XCTAssertEqual(request.syncState.publishTracks[0].cid, "test-cid")
        XCTAssertEqual(request.syncState.dataChannels.count, 1)
        XCTAssertEqual(request.syncState.dataChannels[0].label, "test-dc")
    }

    // MARK: - sendAddTrack with completer

    func testSendAddTrackSendsCorrectRequest() async throws {
        // We'll test just the request sending, not the completer wait
        // (waiting would block forever without a trackPublished response)
        let client = signalClient!
        let addTrackTask = Task<Livekit_TrackInfo, Error> {
            try await client.sendAddTrack(
                cid: "test-cid-123",
                name: "camera",
                type: .video,
                source: .camera,
                encryption: .none
            ) { request in
                request.width = 1920
                request.height = 1080
            }
        }

        // Wait for the request to be sent
        await waitForQueue()

        // Verify the add track request was sent
        let addTrackRequests = mockSocket.sentRequests.filter {
            if case .addTrack = $0.message { return true }
            return false
        }
        XCTAssertEqual(addTrackRequests.count, 1)
        XCTAssertEqual(addTrackRequests[0].addTrack.cid, "test-cid-123")
        XCTAssertEqual(addTrackRequests[0].addTrack.name, "camera")
        XCTAssertEqual(addTrackRequests[0].addTrack.type, .video)
        XCTAssertEqual(addTrackRequests[0].addTrack.source, .camera)
        XCTAssertEqual(addTrackRequests[0].addTrack.width, 1920)

        // Now simulate the server responding with trackPublished to resolve the completer
        let trackInfo = TestData.trackInfo(sid: "TR_pub1", name: "camera", type: .video, source: .camera)
        let publishedResponse = Livekit_SignalResponse.with {
            $0.trackPublished = Livekit_TrackPublishedResponse.with {
                $0.cid = "test-cid-123"
                $0.track = trackInfo
            }
        }
        await signalClient._process(signalResponse: publishedResponse)

        // The task should now complete
        let result = try await addTrackTask.value
        XCTAssertEqual(result.sid, "TR_pub1")
    }
}
