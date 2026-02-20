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

class AgentStateTests: LKTestCase {
    // MARK: - Initial State (Disconnected)

    func testInitialStateIsDisconnected() {
        let agent = Agent()
        XCTAssertTrue(agent.isFinished)
        XCTAssertFalse(agent.isConnected)
        XCTAssertFalse(agent.canListen)
        XCTAssertFalse(agent.isPending)
    }

    func testInitialStateAccessorsAreNil() {
        let agent = Agent()
        XCTAssertNil(agent.agentState)
        XCTAssertNil(agent.audioTrack)
        XCTAssertNil(agent.avatarVideoTrack)
        XCTAssertNil(agent.error)
    }

    // MARK: - Connecting State (buffering: false)

    func testConnectingWithoutBufferingIsPending() {
        var agent = Agent()
        agent.connecting(buffering: false)
        XCTAssertTrue(agent.isPending)
        XCTAssertFalse(agent.canListen)
        XCTAssertFalse(agent.isConnected)
        XCTAssertFalse(agent.isFinished)
    }

    // MARK: - Connecting State (buffering: true)

    func testConnectingWithBufferingCanListen() {
        var agent = Agent()
        agent.connecting(buffering: true)
        XCTAssertTrue(agent.canListen)
        XCTAssertFalse(agent.isPending)
        XCTAssertFalse(agent.isConnected)
        XCTAssertFalse(agent.isFinished)
    }

    func testConnectingAccessorsAreNil() {
        var agent = Agent()
        agent.connecting(buffering: true)
        XCTAssertNil(agent.agentState)
        XCTAssertNil(agent.audioTrack)
        XCTAssertNil(agent.avatarVideoTrack)
        XCTAssertNil(agent.error)
    }

    // MARK: - Failed State

    func testFailedWithTimeoutError() {
        var agent = Agent()
        agent.failed(error: .timeout)
        XCTAssertTrue(agent.isFinished)
        XCTAssertFalse(agent.isConnected)
        XCTAssertFalse(agent.canListen)
        XCTAssertFalse(agent.isPending)
    }

    func testFailedWithLeftError() {
        var agent = Agent()
        agent.failed(error: .left)
        XCTAssertTrue(agent.isFinished)
        XCTAssertNotNil(agent.error)
    }

    func testFailedErrorAccessor() {
        var agent = Agent()
        agent.failed(error: .timeout)

        if case .timeout = agent.error {
            // Expected
        } else {
            XCTFail("Expected .timeout error")
        }
    }

    func testFailedErrorDescriptions() {
        XCTAssertNotNil(Agent.Error.timeout.errorDescription)
        XCTAssertNotNil(Agent.Error.left.errorDescription)
    }

    // MARK: - Disconnected Transition

    func testDisconnectedFromConnecting() {
        var agent = Agent()
        agent.connecting(buffering: true)
        XCTAssertFalse(agent.isFinished)

        agent.disconnected()
        XCTAssertTrue(agent.isFinished)
        XCTAssertFalse(agent.canListen)
        XCTAssertNil(agent.error)
    }

    func testDisconnectedFromFailed() {
        var agent = Agent()
        agent.failed(error: .timeout)
        XCTAssertNotNil(agent.error)

        agent.disconnected()
        XCTAssertTrue(agent.isFinished)
        XCTAssertNil(agent.error)
    }

    // MARK: - State Transition Sequences

    func testFullLifecycle() {
        var agent = Agent()

        // Start disconnected
        XCTAssertTrue(agent.isFinished)

        // Begin connecting without buffering
        agent.connecting(buffering: false)
        XCTAssertTrue(agent.isPending)

        // Enable buffering
        agent.connecting(buffering: true)
        XCTAssertTrue(agent.canListen)

        // Disconnect
        agent.disconnected()
        XCTAssertTrue(agent.isFinished)
    }

    func testFailureFromConnecting() {
        var agent = Agent()
        agent.connecting(buffering: true)
        XCTAssertTrue(agent.canListen)

        agent.failed(error: .timeout)
        XCTAssertTrue(agent.isFinished)
        XCTAssertFalse(agent.canListen)
        XCTAssertNotNil(agent.error)
    }

    // MARK: - Connected State (via participant)

    private func makeHelper() -> RoomTestHelper {
        RoomTestHelper()
    }

    func testConnectedWithListeningAgent() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "listening"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        var agent = Agent()
        agent.connected(participant: participant)

        XCTAssertTrue(agent.isConnected)
        XCTAssertTrue(agent.canListen)
        XCTAssertFalse(agent.isPending)
        XCTAssertFalse(agent.isFinished)
        XCTAssertEqual(agent.agentState, .listening)
        // No tracks attached, so audio/video tracks should be nil
        XCTAssertNil(agent.audioTrack)
        XCTAssertNil(agent.avatarVideoTrack)
        XCTAssertNil(agent.error)
    }

    func testConnectedWithSpeakingAgent() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "speaking"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        var agent = Agent()
        agent.connected(participant: participant)

        XCTAssertTrue(agent.isConnected)
        XCTAssertEqual(agent.agentState, .speaking)
    }

    func testConnectedWithThinkingAgent() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "thinking"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        var agent = Agent()
        agent.connected(participant: participant)

        XCTAssertTrue(agent.isConnected)
        XCTAssertTrue(agent.canListen)
        XCTAssertEqual(agent.agentState, .thinking)
    }

    func testConnectedWithIdleAgentIsPending() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "idle"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        var agent = Agent()
        agent.connected(participant: participant)

        XCTAssertFalse(agent.isConnected) // idle is not "connected" in the active sense
        XCTAssertTrue(agent.isPending)
        XCTAssertEqual(agent.agentState, .idle)
    }

    func testConnectedWithInitializingAgentIsPending() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "initializing"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        var agent = Agent()
        agent.connected(participant: participant)

        XCTAssertFalse(agent.isConnected)
        XCTAssertTrue(agent.isPending)
        XCTAssertFalse(agent.canListen)
        XCTAssertEqual(agent.agentState, .initializing)
    }

    func testDisconnectedAfterConnected() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "listening"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        var agent = Agent()
        agent.connected(participant: participant)
        XCTAssertTrue(agent.isConnected)

        agent.disconnected()
        XCTAssertTrue(agent.isFinished)
        XCTAssertNil(agent.agentState)
    }

    func testFailedAfterConnected() {
        let helper = makeHelper()
        let info = TestData.participantInfo(
            sid: "PA_agent", identity: "agent-1",
            attributes: ["lk.agent.state": "speaking"],
            kind: .agent
        )
        let participant = RemoteParticipant(info: info, room: helper.room, connectionState: .connected)

        var agent = Agent()
        agent.connected(participant: participant)
        XCTAssertTrue(agent.isConnected)

        agent.failed(error: .left)
        XCTAssertTrue(agent.isFinished)
        XCTAssertFalse(agent.isConnected)
        XCTAssertNotNil(agent.error)
    }
}
