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

/// Mock token source for testing Session initialization without a real server.
private struct MockFixedTokenSource: TokenSourceFixed {
    let response: TokenSourceResponse

    func fetch() async throws -> TokenSourceResponse {
        response
    }
}

private struct MockConfigurableTokenSource: TokenSourceConfigurable {
    let response: TokenSourceResponse

    func fetch(_: TokenRequestOptions) async throws -> TokenSourceResponse {
        response
    }
}

private struct FailingTokenSource: TokenSourceFixed {
    func fetch() async throws -> TokenSourceResponse {
        throw LiveKitError(.network, message: "Mock token fetch failure")
    }
}

/// Tests for Agent Session error types, message history, and initialization.
@MainActor
class SessionTests: LKTestCase {
    private let mockResponse = TokenSourceResponse(
        serverURL: URL(string: "wss://test.livekit.cloud")!,
        participantToken: "mock-token"
    )

    // MARK: - Session.Error

    func testSessionErrorConnectionDescription() {
        let error = Session.Error.connection(LiveKitError(.network, message: "timeout"))
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Connection failed"))
    }

    func testSessionErrorSenderDescription() {
        let error = Session.Error.sender(LiveKitError(.invalidState, message: "not connected"))
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Message sender failed"))
    }

    func testSessionErrorReceiverDescription() {
        let error = Session.Error.receiver(LiveKitError(.invalidState, message: "stream ended"))
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Message receiver failed"))
    }

    // MARK: - Initialization

    func testInitWithFixedTokenSource() {
        let source = MockFixedTokenSource(response: mockResponse)
        let session = Session(tokenSource: source)
        XCTAssertNotNil(session.room)
        XCTAssertFalse(session.isConnected)
        XCTAssertNil(session.error)
        XCTAssertTrue(session.messages.isEmpty)
    }

    func testInitWithConfigurableTokenSource() {
        let source = MockConfigurableTokenSource(response: mockResponse)
        let session = Session(tokenSource: source, tokenOptions: .init(agentName: "test-agent"))
        XCTAssertNotNil(session.room)
        XCTAssertFalse(session.isConnected)
    }

    func testWithAgentFactory() {
        let source = MockConfigurableTokenSource(response: mockResponse)
        let session = Session.withAgent("my-agent", tokenSource: source)
        XCTAssertNotNil(session.room)
        XCTAssertFalse(session.isConnected)
    }

    func testInitWithCustomSessionOptions() {
        let source = MockFixedTokenSource(response: mockResponse)
        let options = SessionOptions(
            room: Room(),
            preConnectAudio: false,
            agentConnectTimeout: 30
        )
        let session = Session(tokenSource: source, options: options)
        XCTAssertNotNil(session.room)
    }

    // MARK: - isConnected

    func testIsConnectedDefaultFalse() {
        let source = MockFixedTokenSource(response: mockResponse)
        let session = Session(tokenSource: source)
        XCTAssertFalse(session.isConnected)
    }

    // MARK: - Message History

    func testMessagesInitiallyEmpty() {
        let source = MockFixedTokenSource(response: mockResponse)
        let session = Session(tokenSource: source)
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertTrue(session.getMessageHistory().isEmpty)
    }

    func testRestoreMessageHistory() {
        let source = MockFixedTokenSource(response: mockResponse)
        let session = Session(tokenSource: source)

        let messages = [
            ReceivedMessage(id: "msg-1", timestamp: Date(timeIntervalSince1970: 100), content: .userInput("Hello")),
            ReceivedMessage(id: "msg-2", timestamp: Date(timeIntervalSince1970: 200), content: .agentTranscript("Hi there")),
            ReceivedMessage(id: "msg-3", timestamp: Date(timeIntervalSince1970: 300), content: .userTranscript("How are you?")),
        ]

        session.restoreMessageHistory(messages)

        XCTAssertEqual(session.messages.count, 3)
        XCTAssertEqual(session.messages[0].id, "msg-1")
        XCTAssertEqual(session.messages[1].id, "msg-2")
        XCTAssertEqual(session.messages[2].id, "msg-3")
    }

    func testRestoreMessageHistorySortsChronologically() {
        let source = MockFixedTokenSource(response: mockResponse)
        let session = Session(tokenSource: source)

        // Intentionally out of order
        let messages = [
            ReceivedMessage(id: "msg-3", timestamp: Date(timeIntervalSince1970: 300), content: .userInput("Third")),
            ReceivedMessage(id: "msg-1", timestamp: Date(timeIntervalSince1970: 100), content: .userInput("First")),
            ReceivedMessage(id: "msg-2", timestamp: Date(timeIntervalSince1970: 200), content: .userInput("Second")),
        ]

        session.restoreMessageHistory(messages)

        XCTAssertEqual(session.messages[0].id, "msg-1")
        XCTAssertEqual(session.messages[1].id, "msg-2")
        XCTAssertEqual(session.messages[2].id, "msg-3")
    }

    func testRestoreMessageHistoryReplacesExisting() {
        let source = MockFixedTokenSource(response: mockResponse)
        let session = Session(tokenSource: source)

        let initial = [ReceivedMessage(id: "old", timestamp: Date(), content: .userInput("old"))]
        session.restoreMessageHistory(initial)
        XCTAssertEqual(session.messages.count, 1)

        let replacement = [ReceivedMessage(id: "new", timestamp: Date(), content: .userInput("new"))]
        session.restoreMessageHistory(replacement)
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].id, "new")
    }

    func testGetMessageHistoryReturnsSameAsMessages() {
        let source = MockFixedTokenSource(response: mockResponse)
        let session = Session(tokenSource: source)

        let messages = [ReceivedMessage(id: "msg-1", timestamp: Date(), content: .userInput("test"))]
        session.restoreMessageHistory(messages)

        XCTAssertEqual(session.getMessageHistory().count, session.messages.count)
        XCTAssertEqual(session.getMessageHistory().first?.id, session.messages.first?.id)
    }

    // MARK: - dismissError

    func testDismissError() {
        let source = MockFixedTokenSource(response: mockResponse)
        let session = Session(tokenSource: source)

        // Verify dismissError clears error
        session.dismissError()
        XCTAssertNil(session.error)
    }

    // MARK: - Agent initial state

    func testAgentInitialState() {
        let source = MockFixedTokenSource(response: mockResponse)
        let session = Session(tokenSource: source)

        XCTAssertTrue(session.agent.isFinished)
        XCTAssertFalse(session.agent.isConnected)
        XCTAssertNil(session.agent.agentState)
    }

    // MARK: - start() with failing token source

    func testStartWithFailingTokenSetsError() async {
        let source = FailingTokenSource()
        let options = SessionOptions(preConnectAudio: false)
        let session = Session(tokenSource: source, options: options)

        await session.start()

        // Should have set a connection error
        if case .connection = session.error {
            // Expected
        } else {
            XCTFail("Expected .connection error, got \(String(describing: session.error))")
        }

        // Agent should be disconnected after failure
        XCTAssertTrue(session.agent.isFinished)
    }
}
