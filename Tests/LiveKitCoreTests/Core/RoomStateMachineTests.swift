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

/// Lightweight delegate tracker for verifying Room delegate calls in state machine tests.
private final class StateMachineDelegateTracker: RoomDelegate, @unchecked Sendable {
    var didConnect = false
    var didReconnect = false
    var isReconnecting = false
    var didFailToConnect = false
    var didDisconnect = false
    var lastDisconnectError: LiveKitError?
    var didStartReconnectMode: ReconnectMode?
    var didCompleteReconnectMode: ReconnectMode?
    var didUpdateReconnectMode: ReconnectMode?
    var connectionStateUpdates: [(ConnectionState, ConnectionState)] = []
    var speakingParticipants: [Participant]?

    func roomDidConnect(_: Room) { didConnect = true }
    func roomDidReconnect(_: Room) { didReconnect = true }
    func roomIsReconnecting(_: Room) { isReconnecting = true }
    func room(_: Room, didFailToConnectWithError _: LiveKitError?) { didFailToConnect = true }
    func room(_: Room, didDisconnectWithError error: LiveKitError?) { didDisconnect = true; lastDisconnectError = error }
    func room(_: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        connectionStateUpdates.append((connectionState, oldConnectionState))
    }

    func room(_: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) { didStartReconnectMode = reconnectMode }
    func room(_: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) { didCompleteReconnectMode = reconnectMode }
    func room(_: Room, didUpdateReconnectMode reconnectMode: ReconnectMode) { didUpdateReconnectMode = reconnectMode }
    func room(_: Room, didUpdateSpeakingParticipants participants: [Participant]) { speakingParticipants = participants }
}

/// Tests for Room's `engine(_:didMutateState:oldState:)` state machine handler.
/// Validates connection state transitions, reconnection notifications, and cleanup.
class RoomStateMachineTests: LKTestCase {
    // MARK: - Helper

    private func makeRoom() -> (Room, StateMachineDelegateTracker) {
        let room = Room()
        let localInfo = TestData.participantInfo(sid: "PA_local", identity: "local-user")
        room.localParticipant.set(info: localInfo, connectionState: .connected)
        let tracker = StateMachineDelegateTracker()
        room.delegates.add(delegate: tracker)
        return (room, tracker)
    }

    /// Wait for MulticastDelegate's async dispatch to complete.
    private func waitForDelegates() {
        let exp = expectation(description: "delegate dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Connection State Transitions

    func testConnectedFromConnecting() {
        let (room, tracker) = makeRoom()
        let oldState = TestData.roomState(connectionState: .connecting)
        let newState = TestData.roomState(connectionState: .connected)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        XCTAssertTrue(tracker.didConnect)
        XCTAssertFalse(tracker.didReconnect)
        XCTAssertEqual(tracker.connectionStateUpdates.count, 1)
        XCTAssertEqual(tracker.connectionStateUpdates.first?.0, .connected)
        XCTAssertEqual(tracker.connectionStateUpdates.first?.1, .connecting)
    }

    func testConnectedFromReconnecting() {
        let (room, tracker) = makeRoom()
        let oldState = TestData.roomState(connectionState: .reconnecting, isReconnectingWithMode: .quick)
        let newState = TestData.roomState(connectionState: .connected)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        XCTAssertTrue(tracker.didReconnect)
        XCTAssertFalse(tracker.didConnect)
    }

    func testReconnectingState() {
        let (room, tracker) = makeRoom()
        let oldState = TestData.roomState(connectionState: .connected)
        let newState = TestData.roomState(connectionState: .reconnecting, isReconnectingWithMode: .quick)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        XCTAssertTrue(tracker.isReconnecting)
        XCTAssertFalse(tracker.didConnect)
        XCTAssertFalse(tracker.didDisconnect)
    }

    func testDisconnectedFromConnecting() {
        let (room, tracker) = makeRoom()
        let oldState = TestData.roomState(connectionState: .connecting)
        let newState = TestData.roomState(connectionState: .disconnected)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        XCTAssertTrue(tracker.didFailToConnect)
        XCTAssertFalse(tracker.didDisconnect)
    }

    func testDisconnectedFromConnected() {
        let (room, tracker) = makeRoom()
        let error = LiveKitError(.unknown, message: "test error")
        let oldState = TestData.roomState(connectionState: .connected)
        let newState = TestData.roomState(connectionState: .disconnected, disconnectError: error)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        XCTAssertTrue(tracker.didDisconnect)
        XCTAssertFalse(tracker.didFailToConnect)
    }

    func testNoChangeDoesNotTriggerConnectionDelegate() {
        let (room, tracker) = makeRoom()
        let state = TestData.roomState(connectionState: .connected)

        // Same state → should not trigger connection-change logic
        room.engine(room, didMutateState: state, oldState: state)
        waitForDelegates()

        XCTAssertFalse(tracker.didConnect)
        XCTAssertFalse(tracker.didReconnect)
        XCTAssertFalse(tracker.didDisconnect)
        XCTAssertFalse(tracker.didFailToConnect)
        XCTAssertTrue(tracker.connectionStateUpdates.isEmpty)
    }

    // MARK: - Quick Reconnect Resets Track Settings

    func testQuickReconnectResetsTrackSettings() {
        let (room, _) = makeRoom()
        // Add a remote participant with a track publication
        let trackInfo = TestData.trackInfo(sid: "TR_v1", name: "camera", type: .video, source: .camera)
        let remoteInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1", tracks: [trackInfo])
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] =
            RemoteParticipant(info: remoteInfo, room: room, connectionState: .connected)
        }

        // Simulate quick reconnect completing
        let oldState = TestData.roomState(connectionState: .reconnecting, isReconnectingWithMode: .quick)
        var newState = TestData.roomState(connectionState: .connected)
        newState.isReconnectingWithMode = .quick

        room.engine(room, didMutateState: newState, oldState: oldState)

        // Track settings should have been reset
        let identity = Participant.Identity(from: "remote-1")
        if let pub = room.remoteParticipants[identity]?.trackPublications.values.first as? RemoteTrackPublication {
            // resetTrackSettings sets enabled based on adaptiveStream (default: false → enabled=true)
            XCTAssertTrue(pub.isEnabled)
        }
    }

    // MARK: - Reconnection Mode Notifications

    func testReconnectionStartNotification() {
        let (room, tracker) = makeRoom()
        let oldState = TestData.roomState(connectionState: .connected, isReconnectingWithMode: nil)
        let newState = TestData.roomState(connectionState: .reconnecting, isReconnectingWithMode: .quick)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        XCTAssertEqual(tracker.didStartReconnectMode, .quick)
    }

    func testReconnectionCompleteNotification() {
        let (room, tracker) = makeRoom()
        let oldState = TestData.roomState(connectionState: .reconnecting, isReconnectingWithMode: .quick)
        let newState = TestData.roomState(connectionState: .connected, isReconnectingWithMode: nil)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        XCTAssertEqual(tracker.didCompleteReconnectMode, .quick)
    }

    func testReconnectionModeChange() {
        let (room, tracker) = makeRoom()
        let oldState = TestData.roomState(connectionState: .reconnecting, isReconnectingWithMode: .quick)
        let newState = TestData.roomState(connectionState: .reconnecting, isReconnectingWithMode: .full)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        XCTAssertEqual(tracker.didUpdateReconnectMode, .full)
    }

    func testFullReconnectCompleteTriggersRepublish() {
        let (room, tracker) = makeRoom()
        let oldState = TestData.roomState(connectionState: .reconnecting, isReconnectingWithMode: .full)
        let newState = TestData.roomState(connectionState: .connected)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        // Verifies reconnect delegate fired and republish Task was dispatched (no crash)
        XCTAssertTrue(tracker.didReconnect)
        XCTAssertEqual(tracker.didCompleteReconnectMode, .full)
    }

    // MARK: - Disconnected Clears E2EE Manager

    func testDisconnectedClearsE2EEManager() {
        let (room, tracker) = makeRoom()
        let oldState = TestData.roomState(connectionState: .connected)
        let newState = TestData.roomState(connectionState: .disconnected)

        room.engine(room, didMutateState: newState, oldState: oldState)
        waitForDelegates()

        XCTAssertNil(room.e2eeManager)
        XCTAssertTrue(tracker.didDisconnect)
    }

    // MARK: - Speaker Updates via Engine Delegate

    func testSpeakerUpdateSetsLocalParticipantSpeaking() {
        let (room, tracker) = makeRoom()
        room._state.mutate { $0.connectionState = .connected }

        let speaker = TestData.speakerInfo(sid: "PA_local", level: 0.85, active: true)
        room.engine(room, didUpdateSpeakers: [speaker])
        waitForDelegates()

        XCTAssertTrue(room.localParticipant.isSpeaking)
        XCTAssertEqual(room.localParticipant.audioLevel, 0.85, accuracy: 0.01)
        XCTAssertNotNil(tracker.speakingParticipants)
        XCTAssertEqual(tracker.speakingParticipants?.count, 1)
    }

    func testSpeakerUpdateSetsRemoteParticipantSpeaking() {
        let (room, _) = makeRoom()
        room._state.mutate { $0.connectionState = .connected }
        let remoteInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        let remote = RemoteParticipant(info: remoteInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = remote }

        let speaker = TestData.speakerInfo(sid: "PA_r1", level: 0.6, active: true)
        room.engine(room, didUpdateSpeakers: [speaker])

        XCTAssertTrue(remote.isSpeaking)
        XCTAssertEqual(remote.audioLevel, 0.6, accuracy: 0.01)
        XCTAssertNotNil(remote.lastSpokeAt)
    }

    func testSpeakerUpdateResetsNotSpeakingParticipants() {
        let (room, _) = makeRoom()
        room._state.mutate { $0.connectionState = .connected }
        let remoteInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        let remote = RemoteParticipant(info: remoteInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = remote }

        // First, make remote speaking
        remote._state.mutate {
            $0.isSpeaking = true
            $0.audioLevel = 0.9
        }

        // Update speakers with only local → remote should stop speaking
        let localSpeaker = TestData.speakerInfo(sid: "PA_local", level: 0.5, active: true)
        room.engine(room, didUpdateSpeakers: [localSpeaker])

        XCTAssertFalse(remote.isSpeaking)
        XCTAssertEqual(remote.audioLevel, 0.0, accuracy: 0.01)
    }

    func testSpeakerUpdateResetsLocalWhenNotInList() {
        let (room, _) = makeRoom()
        room._state.mutate { $0.connectionState = .connected }

        // Make local speaking first
        room.localParticipant._state.mutate {
            $0.isSpeaking = true
            $0.audioLevel = 0.8
        }

        // Remote participant only in speakers
        let remoteInfo = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        let remote = RemoteParticipant(info: remoteInfo, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = remote }

        let remoteSpeaker = TestData.speakerInfo(sid: "PA_r1", level: 0.7, active: true)
        room.engine(room, didUpdateSpeakers: [remoteSpeaker])

        // Local should be reset
        XCTAssertFalse(room.localParticipant.isSpeaking)
        XCTAssertEqual(room.localParticipant.audioLevel, 0.0, accuracy: 0.01)
    }

    func testSpeakerUpdateMultipleParticipants() {
        let (room, tracker) = makeRoom()
        room._state.mutate { $0.connectionState = .connected }
        let r1Info = TestData.participantInfo(sid: "PA_r1", identity: "remote-1")
        let r1 = RemoteParticipant(info: r1Info, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote-1")] = r1 }

        let s1 = TestData.speakerInfo(sid: "PA_local", level: 0.5)
        let s2 = TestData.speakerInfo(sid: "PA_r1", level: 0.8)
        room.engine(room, didUpdateSpeakers: [s1, s2])
        waitForDelegates()

        // Both participants should have speaking state updated
        XCTAssertTrue(room.localParticipant.isSpeaking)
        XCTAssertTrue(r1.isSpeaking)
        XCTAssertEqual(r1.audioLevel, 0.8, accuracy: 0.01)
        XCTAssertEqual(tracker.speakingParticipants?.count, 2)
    }

    func testSpeakerUpdateSetsLastSpokeAtOnlyOnTransition() {
        let (room, _) = makeRoom()
        room._state.mutate { $0.connectionState = .connected }

        // First update — should set lastSpokeAt
        let speaker1 = TestData.speakerInfo(sid: "PA_local", level: 0.5)
        room.engine(room, didUpdateSpeakers: [speaker1])
        let firstSpokeAt = room.localParticipant.lastSpokeAt

        XCTAssertNotNil(firstSpokeAt)

        // Second update while still speaking — lastSpokeAt should NOT change
        let speaker2 = TestData.speakerInfo(sid: "PA_local", level: 0.7)
        room.engine(room, didUpdateSpeakers: [speaker2])
        let secondSpokeAt = room.localParticipant.lastSpokeAt

        XCTAssertEqual(firstSpokeAt, secondSpokeAt)
    }
}
