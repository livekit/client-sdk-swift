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

// swiftlint:disable file_length
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
import LiveKitUniFFI

// swiftlint:disable:next type_body_length
class TokenSourceTests: LKTestCase {
    actor MockValidJWTSource: TokenSourceConfigurable {
        let serverURL = URL(string: "wss://test.livekit.io")!
        let participantName: String
        var callCount = 0

        init(participantName: String = "test-participant") {
            self.participantName = participantName
        }

        func fetch(_ options: TokenRequestOptions) async throws -> TokenSourceResponse {
            callCount += 1

            let tokenGenerator = TokenGenerator(
                apiKey: "test-api-key",
                apiSecret: "test-api-secret",
                identity: options.participantIdentity ?? "test-identity"
            )
            tokenGenerator.name = options.participantName ?? participantName
            tokenGenerator.roomConfiguration = RoomConfiguration(
                name: options.roomName ?? "test-room",
                emptyTimeout: 0,
                departureTimeout: 0,
                maxParticipants: 0,
                metadata: "",
                minPlayoutDelay: 0,
                maxPlayoutDelay: 0,
                syncStreams: false,
                agents: []
            )

            let token = try tokenGenerator.sign()

            return TokenSourceResponse(
                serverURL: serverURL,
                participantToken: token
            )
        }
    }

    actor MockInvalidJWTSource: TokenSourceConfigurable {
        let serverURL = URL(string: "wss://test.livekit.io")!
        var callCount = 0

        func fetch(_: TokenRequestOptions) async throws -> TokenSourceResponse {
            callCount += 1

            return TokenSourceResponse(
                serverURL: serverURL,
                participantToken: "invalid.jwt.token"
            )
        }
    }

    actor MockExpiredJWTSource: TokenSourceConfigurable {
        let serverURL = URL(string: "wss://test.livekit.io")!
        var callCount = 0

        func fetch(_ options: TokenRequestOptions) async throws -> TokenSourceResponse {
            callCount += 1

            let tokenGenerator = TokenGenerator(
                apiKey: "test-api-key",
                apiSecret: "test-api-secret",
                identity: options.participantIdentity ?? "test-identity",
                ttl: 0
            )
            tokenGenerator.name = options.participantName ?? "test-participant"
            tokenGenerator.roomConfiguration = RoomConfiguration(
                name: options.roomName ?? "test-room",
                emptyTimeout: 0,
                departureTimeout: 0,
                maxParticipants: 0,
                metadata: "",
                minPlayoutDelay: 0,
                maxPlayoutDelay: 0,
                syncStreams: false,
                agents: []
            )

            let token = try tokenGenerator.sign()

            return TokenSourceResponse(
                serverURL: serverURL,
                participantToken: token
            )
        }
    }

    func testValidJWTCaching() async throws {
        let mockSource = MockValidJWTSource(participantName: "alice")
        let cachingSource = CachingTokenSource(mockSource)

        let request = TokenRequestOptions(
            roomName: "test-room",
            participantName: "alice",
            participantIdentity: "alice-id"
        )

        let response1 = try await cachingSource.fetch(request)
        let callCount1 = await mockSource.callCount
        XCTAssertEqual(callCount1, 1)
        XCTAssertEqual(response1.serverURL.absoluteString, "wss://test.livekit.io")
        XCTAssertTrue(response1.hasValidToken(), "Generated token should be valid")

        let response2 = try await cachingSource.fetch(request)
        let callCount2 = await mockSource.callCount
        XCTAssertEqual(callCount2, 1)
        XCTAssertEqual(response2.participantToken, response1.participantToken)
        XCTAssertEqual(response2.serverURL, response1.serverURL)

        let differentRequest = TokenRequestOptions(
            roomName: "different-room",
            participantName: "alice",
            participantIdentity: "alice-id"
        )
        let response3 = try await cachingSource.fetch(differentRequest)
        let callCount3 = await mockSource.callCount
        XCTAssertEqual(callCount3, 2)
        XCTAssertNotEqual(response3.participantToken, response1.participantToken)

        await cachingSource.invalidate()
        _ = try await cachingSource.fetch(request)
        let callCount4 = await mockSource.callCount
        XCTAssertEqual(callCount4, 3)
    }

    func testInvalidJWTHandling() async throws {
        let mockInvalidSource = MockInvalidJWTSource()
        let cachingSource = CachingTokenSource(mockInvalidSource)

        let request = TokenRequestOptions(
            roomName: "test-room",
            participantName: "bob",
            participantIdentity: "bob-id"
        )

        let response1 = try await cachingSource.fetch(request)
        let callCount1 = await mockInvalidSource.callCount
        XCTAssertEqual(callCount1, 1)
        XCTAssertFalse(response1.hasValidToken(), "Invalid token should not be considered valid")

        let response2 = try await cachingSource.fetch(request)
        let callCount2 = await mockInvalidSource.callCount
        XCTAssertEqual(callCount2, 2)
        XCTAssertEqual(response2.participantToken, response1.participantToken)

        let mockExpiredSource = MockExpiredJWTSource()
        let cachingSourceExpired = CachingTokenSource(mockExpiredSource)

        let response3 = try await cachingSourceExpired.fetch(request)
        let expiredCallCount1 = await mockExpiredSource.callCount
        XCTAssertEqual(expiredCallCount1, 1)
        XCTAssertFalse(response3.hasValidToken(), "Expired token should not be considered valid")

        _ = try await cachingSourceExpired.fetch(request)
        let expiredCallCount2 = await mockExpiredSource.callCount
        XCTAssertEqual(expiredCallCount2, 2)
    }

    // swiftlint:disable:next function_body_length
    func testCustomValidator() async throws {
        let mockSource = MockValidJWTSource(participantName: "charlie")

        let customValidator: CachingTokenSource.Validator = { request, response in
            request.participantName == "charlie" && response.hasValidToken()
        }

        let cachingSource = CachingTokenSource(mockSource, validator: customValidator)

        let charlieRequest = TokenRequestOptions(
            roomName: "test-room",
            participantName: "charlie",
            participantIdentity: "charlie-id"
        )

        let response1 = try await cachingSource.fetch(charlieRequest)
        let callCount1 = await mockSource.callCount
        XCTAssertEqual(callCount1, 1)
        XCTAssertTrue(response1.hasValidToken())

        let response2 = try await cachingSource.fetch(charlieRequest)
        let callCount2 = await mockSource.callCount
        XCTAssertEqual(callCount2, 1)
        XCTAssertEqual(response2.participantToken, response1.participantToken)

        let aliceRequest = TokenRequestOptions(
            roomName: "test-room",
            participantName: "alice",
            participantIdentity: "alice-id"
        )

        _ = try await cachingSource.fetch(aliceRequest)
        let callCount3 = await mockSource.callCount
        XCTAssertEqual(callCount3, 2)

        _ = try await cachingSource.fetch(aliceRequest)
        let callCount4 = await mockSource.callCount
        XCTAssertEqual(callCount4, 3)

        let tokenMockSource = MockValidJWTSource(participantName: "dave")
        let tokenContentValidator: CachingTokenSource.Validator = { request, response in
            request.roomName == "test-room" && response.hasValidToken()
        }

        let tokenCachingSource = CachingTokenSource(tokenMockSource, validator: tokenContentValidator)

        let roomRequest = TokenRequestOptions(
            roomName: "test-room",
            participantName: "dave",
            participantIdentity: "dave-id"
        )

        _ = try await tokenCachingSource.fetch(roomRequest)
        let tokenCallCount1 = await tokenMockSource.callCount
        XCTAssertEqual(tokenCallCount1, 1)

        _ = try await tokenCachingSource.fetch(roomRequest)
        let tokenCallCount2 = await tokenMockSource.callCount
        XCTAssertEqual(tokenCallCount2, 1)

        let differentRoomRequest = TokenRequestOptions(
            roomName: "different-room",
            participantName: "dave",
            participantIdentity: "dave-id"
        )

        _ = try await tokenCachingSource.fetch(differentRoomRequest)
        let tokenCallCount3 = await tokenMockSource.callCount
        XCTAssertEqual(tokenCallCount3, 2)

        _ = try await tokenCachingSource.fetch(differentRoomRequest)
        let tokenCallCount4 = await tokenMockSource.callCount
        XCTAssertEqual(tokenCallCount4, 3)
    }

    func testConcurrentAccess() async throws {
        let mockSource = MockValidJWTSource(participantName: "concurrent-test")
        let cachingSource = CachingTokenSource(mockSource)

        let request = TokenRequestOptions(
            roomName: "concurrent-room",
            participantName: "concurrent-user",
            participantIdentity: "concurrent-id"
        )

        let initialResponse = try await cachingSource.fetch(request)
        let initialCallCount = await mockSource.callCount
        XCTAssertEqual(initialCallCount, 1)

        async let fetch1 = cachingSource.fetch(request)
        async let fetch2 = cachingSource.fetch(request)
        async let fetch3 = cachingSource.fetch(request)

        let responses = try await [fetch1, fetch2, fetch3]

        XCTAssertEqual(responses[0].participantToken, initialResponse.participantToken)
        XCTAssertEqual(responses[1].participantToken, initialResponse.participantToken)
        XCTAssertEqual(responses[2].participantToken, initialResponse.participantToken)

        XCTAssertEqual(responses[0].serverURL, initialResponse.serverURL)
        XCTAssertEqual(responses[1].serverURL, initialResponse.serverURL)
        XCTAssertEqual(responses[2].serverURL, initialResponse.serverURL)

        let finalCallCount = await mockSource.callCount
        XCTAssertEqual(finalCallCount, 1)
    }

    // MARK: - LiteralTokenSource

    func testLiteralTokenSourceReturnsFixedCredentials() async throws {
        let serverURL = URL(string: "wss://my-server.livekit.cloud")!
        let source = LiteralTokenSource(
            serverURL: serverURL,
            participantToken: "test-token-123",
            participantName: "Alice",
            roomName: "test-room"
        )

        let response = try await source.fetch()
        XCTAssertEqual(response.serverURL, serverURL)
        XCTAssertEqual(response.participantToken, "test-token-123")
        XCTAssertEqual(response.participantName, "Alice")
        XCTAssertEqual(response.roomName, "test-room")
    }

    func testLiteralTokenSourceWithOptionalFieldsNil() async throws {
        let serverURL = URL(string: "wss://example.com")!
        let source = LiteralTokenSource(
            serverURL: serverURL,
            participantToken: "token"
        )

        let response = try await source.fetch()
        XCTAssertEqual(response.serverURL, serverURL)
        XCTAssertEqual(response.participantToken, "token")
        XCTAssertNil(response.participantName)
        XCTAssertNil(response.roomName)
    }

    func testLiteralTokenSourceReturnsSameValueEveryTime() async throws {
        let source = LiteralTokenSource(
            serverURL: URL(string: "wss://example.com")!,
            participantToken: "fixed-token"
        )

        let response1 = try await source.fetch()
        let response2 = try await source.fetch()
        XCTAssertEqual(response1.participantToken, response2.participantToken)
        XCTAssertEqual(response1.serverURL, response2.serverURL)
    }

    // MARK: - SandboxTokenSource

    func testSandboxTokenSourceURL() {
        let source = SandboxTokenSource(id: "test-sandbox-id")
        XCTAssertEqual(source.url.absoluteString, "https://cloud-api.livekit.io/api/v2/sandbox/connection-details")
    }

    func testSandboxTokenSourceHeaders() {
        let source = SandboxTokenSource(id: "my-sandbox-id")
        XCTAssertEqual(source.headers["X-Sandbox-ID"], "my-sandbox-id")
    }

    func testSandboxTokenSourceTrimsNonAlphanumericCharacters() {
        // trimmingCharacters(in: .alphanumerics.inverted) strips non-alphanumeric from edges
        let source = SandboxTokenSource(id: "  test-id  ")
        XCTAssertEqual(source.id, "test-id")

        let source2 = SandboxTokenSource(id: "abc123")
        XCTAssertEqual(source2.id, "abc123")
    }

    func testSandboxTokenSourceMethodIsPOST() {
        let source = SandboxTokenSource(id: "test")
        XCTAssertEqual(source.method, "POST")
    }

    // MARK: - TokenSourceResponse Decoding

    func testTokenSourceResponseDecoding() throws {
        let json = """
        {
            "server_url": "wss://example.livekit.cloud",
            "participant_token": "jwt-token-here",
            "participant_name": "Alice",
            "room_name": "test-room"
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokenSourceResponse.self, from: data)
        XCTAssertEqual(response.serverURL.absoluteString, "wss://example.livekit.cloud")
        XCTAssertEqual(response.participantToken, "jwt-token-here")
        XCTAssertEqual(response.participantName, "Alice")
        XCTAssertEqual(response.roomName, "test-room")
    }

    func testTokenSourceResponseDecodingMinimalFields() throws {
        let json = """
        {
            "server_url": "wss://example.com",
            "participant_token": "token"
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokenSourceResponse.self, from: data)
        XCTAssertEqual(response.serverURL.absoluteString, "wss://example.com")
        XCTAssertEqual(response.participantToken, "token")
        XCTAssertNil(response.participantName)
        XCTAssertNil(response.roomName)
    }

    // MARK: - Token Validation

    func testHasValidTokenWithValidJWT() async throws {
        let mockSource = MockValidJWTSource()
        let request = TokenRequestOptions(
            roomName: "room",
            participantName: "user",
            participantIdentity: "user-id"
        )
        let response = try await mockSource.fetch(request)
        XCTAssertTrue(response.hasValidToken())
    }

    func testHasValidTokenWithInvalidJWT() {
        let response = TokenSourceResponse(
            serverURL: URL(string: "wss://example.com")!,
            participantToken: "not-a-jwt"
        )
        XCTAssertFalse(response.hasValidToken())
    }

    func testHasValidTokenWithExpiredJWT() async throws {
        let mockSource = MockExpiredJWTSource()
        let request = TokenRequestOptions(
            roomName: "room",
            participantName: "user",
            participantIdentity: "user-id"
        )
        let response = try await mockSource.fetch(request)
        XCTAssertFalse(response.hasValidToken())
    }

    func testDispatchesAgentWithNoAgents() async throws {
        let mockSource = MockValidJWTSource()
        let request = TokenRequestOptions(
            roomName: "room",
            participantName: "user",
            participantIdentity: "user-id"
        )
        let response = try await mockSource.fetch(request)
        // MockValidJWTSource sets agents to empty array
        XCTAssertFalse(response.dispatchesAgent())
    }

    func testDispatchesAgentWithInvalidToken() {
        let response = TokenSourceResponse(
            serverURL: URL(string: "wss://example.com")!,
            participantToken: "invalid"
        )
        XCTAssertFalse(response.dispatchesAgent())
    }

    // MARK: - TokenRequestOptions

    func testTokenRequestOptionsEquality() {
        let a = TokenRequestOptions(roomName: "room", participantName: "alice")
        let b = TokenRequestOptions(roomName: "room", participantName: "alice")
        XCTAssertEqual(a, b)
    }

    func testTokenRequestOptionsInequality() {
        let a = TokenRequestOptions(roomName: "room1")
        let b = TokenRequestOptions(roomName: "room2")
        XCTAssertNotEqual(a, b)
    }

    func testTokenRequestOptionsToRequest() {
        let options = TokenRequestOptions(
            roomName: "my-room",
            participantName: "alice",
            participantIdentity: "alice-id",
            agentName: "my-agent"
        )

        let request = options.toRequest()
        XCTAssertEqual(request.roomName, "my-room")
        XCTAssertEqual(request.participantName, "alice")
        XCTAssertEqual(request.participantIdentity, "alice-id")
        XCTAssertNotNil(request.roomConfiguration?.agents)
        XCTAssertEqual(request.roomConfiguration?.agents?.count, 1)
    }

    func testTokenRequestOptionsToRequestWithoutAgent() {
        let options = TokenRequestOptions(
            roomName: "my-room",
            participantName: "alice"
        )

        let request = options.toRequest()
        XCTAssertNil(request.roomConfiguration?.agents)
    }

    // MARK: - InMemoryTokenStore

    func testInMemoryTokenStore() async {
        let store = InMemoryTokenStore()

        // Initially empty
        let initial = await store.retrieve()
        XCTAssertNil(initial)

        // Store and retrieve
        let options = TokenRequestOptions(roomName: "room")
        let response = TokenSourceResponse(
            serverURL: URL(string: "wss://example.com")!,
            participantToken: "token"
        )
        await store.store((options, response))
        let cached = await store.retrieve()
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.0, options)
        XCTAssertEqual(cached?.1.participantToken, "token")

        // Clear
        await store.clear()
        let afterClear = await store.retrieve()
        XCTAssertNil(afterClear)
    }

    // MARK: - CachingTokenSource.cachedResponse

    func testCachedResponseReturnsNilBeforeFetch() async {
        let mockSource = MockValidJWTSource()
        let cachingSource = CachingTokenSource(mockSource)
        let cached = await cachingSource.cachedResponse()
        XCTAssertNil(cached)
    }

    func testCachedResponseReturnsValueAfterFetch() async throws {
        let mockSource = MockValidJWTSource()
        let cachingSource = CachingTokenSource(mockSource)
        let request = TokenRequestOptions(
            roomName: "room",
            participantName: "user",
            participantIdentity: "user-id"
        )
        let response = try await cachingSource.fetch(request)
        let cached = await cachingSource.cachedResponse()
        XCTAssertEqual(cached?.participantToken, response.participantToken)
    }
}
