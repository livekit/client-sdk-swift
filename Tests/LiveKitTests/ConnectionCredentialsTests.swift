/*
 * Copyright 2025 LiveKit
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

import Foundation
@testable import LiveKit
import XCTest

class ConnectionCredentialsTests: LKTestCase {
    actor MockValidJWTProvider: CredentialsProvider {
        let serverUrl = URL(string: "wss://test.livekit.io")!
        let participantName: String
        var callCount = 0

        init(participantName: String = "test-participant") {
            self.participantName = participantName
        }

        func fetch(_ request: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response {
            callCount += 1

            let tokenGenerator = TokenGenerator(
                apiKey: "test-api-key",
                apiSecret: "test-api-secret",
                identity: request.participantIdentity ?? "test-identity"
            )
            tokenGenerator.name = request.participantName ?? participantName
            tokenGenerator.videoGrant = VideoGrant(room: request.roomName ?? "test-room", roomJoin: true)

            let token = try tokenGenerator.sign()

            return ConnectionCredentials.Response(
                serverUrl: serverUrl,
                participantToken: token
            )
        }
    }

    actor MockInvalidJWTProvider: CredentialsProvider {
        let serverUrl = URL(string: "wss://test.livekit.io")!
        var callCount = 0

        func fetch(_: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response {
            callCount += 1

            return ConnectionCredentials.Response(
                serverUrl: serverUrl,
                participantToken: "invalid.jwt.token"
            )
        }
    }

    actor MockExpiredJWTProvider: CredentialsProvider {
        let serverUrl = URL(string: "wss://test.livekit.io")!
        var callCount = 0

        func fetch(_ request: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response {
            callCount += 1

            let tokenGenerator = TokenGenerator(
                apiKey: "test-api-key",
                apiSecret: "test-api-secret",
                identity: request.participantIdentity ?? "test-identity",
                ttl: -60
            )
            tokenGenerator.name = request.participantName ?? "test-participant"
            tokenGenerator.videoGrant = VideoGrant(room: request.roomName ?? "test-room", roomJoin: true)

            let token = try tokenGenerator.sign()

            return ConnectionCredentials.Response(
                serverUrl: serverUrl,
                participantToken: token
            )
        }
    }

    func testValidJWTCaching() async throws {
        let mockProvider = MockValidJWTProvider(participantName: "alice")
        let cachingProvider = CachingCredentialsProvider(mockProvider)

        let request = ConnectionCredentials.Request(
            roomName: "test-room",
            participantName: "alice",
            participantIdentity: "alice-id"
        )

        let response1 = try await cachingProvider.fetch(request)
        let callCount1 = await mockProvider.callCount
        XCTAssertEqual(callCount1, 1)
        XCTAssertEqual(response1.serverUrl.absoluteString, "wss://test.livekit.io")
        XCTAssertTrue(response1.hasValidToken(), "Generated token should be valid")

        let response2 = try await cachingProvider.fetch(request)
        let callCount2 = await mockProvider.callCount
        XCTAssertEqual(callCount2, 1)
        XCTAssertEqual(response2.participantToken, response1.participantToken)
        XCTAssertEqual(response2.serverUrl, response1.serverUrl)

        let differentRequest = ConnectionCredentials.Request(
            roomName: "different-room",
            participantName: "alice",
            participantIdentity: "alice-id"
        )
        let response3 = try await cachingProvider.fetch(differentRequest)
        let callCount3 = await mockProvider.callCount
        XCTAssertEqual(callCount3, 2)
        XCTAssertNotEqual(response3.participantToken, response1.participantToken)

        await cachingProvider.invalidate()
        _ = try await cachingProvider.fetch(request)
        let callCount4 = await mockProvider.callCount
        XCTAssertEqual(callCount4, 3)
    }

    func testInvalidJWTHandling() async throws {
        let mockInvalidProvider = MockInvalidJWTProvider()
        let cachingProvider = CachingCredentialsProvider(mockInvalidProvider)

        let request = ConnectionCredentials.Request(
            roomName: "test-room",
            participantName: "bob",
            participantIdentity: "bob-id"
        )

        let response1 = try await cachingProvider.fetch(request)
        let callCount1 = await mockInvalidProvider.callCount
        XCTAssertEqual(callCount1, 1)
        XCTAssertFalse(response1.hasValidToken(), "Invalid token should not be considered valid")

        let response2 = try await cachingProvider.fetch(request)
        let callCount2 = await mockInvalidProvider.callCount
        XCTAssertEqual(callCount2, 2)
        XCTAssertEqual(response2.participantToken, response1.participantToken)

        let mockExpiredProvider = MockExpiredJWTProvider()
        let cachingProviderExpired = CachingCredentialsProvider(mockExpiredProvider)

        let response3 = try await cachingProviderExpired.fetch(request)
        let expiredCallCount1 = await mockExpiredProvider.callCount
        XCTAssertEqual(expiredCallCount1, 1)
        XCTAssertFalse(response3.hasValidToken(), "Expired token should not be considered valid")

        _ = try await cachingProviderExpired.fetch(request)
        let expiredCallCount2 = await mockExpiredProvider.callCount
        XCTAssertEqual(expiredCallCount2, 2)
    }

    func testCustomValidator() async throws {
        let mockProvider = MockValidJWTProvider(participantName: "charlie")

        let customValidator: CachingCredentialsProvider.Validator = { request, response in
            request.participantName == "charlie" && response.hasValidToken()
        }

        let cachingProvider = CachingCredentialsProvider(mockProvider, validator: customValidator)

        let charlieRequest = ConnectionCredentials.Request(
            roomName: "test-room",
            participantName: "charlie",
            participantIdentity: "charlie-id"
        )

        let response1 = try await cachingProvider.fetch(charlieRequest)
        let callCount1 = await mockProvider.callCount
        XCTAssertEqual(callCount1, 1)
        XCTAssertTrue(response1.hasValidToken())

        let response2 = try await cachingProvider.fetch(charlieRequest)
        let callCount2 = await mockProvider.callCount
        XCTAssertEqual(callCount2, 1)
        XCTAssertEqual(response2.participantToken, response1.participantToken)

        let aliceRequest = ConnectionCredentials.Request(
            roomName: "test-room",
            participantName: "alice",
            participantIdentity: "alice-id"
        )

        _ = try await cachingProvider.fetch(aliceRequest)
        let callCount3 = await mockProvider.callCount
        XCTAssertEqual(callCount3, 2)

        _ = try await cachingProvider.fetch(aliceRequest)
        let callCount4 = await mockProvider.callCount
        XCTAssertEqual(callCount4, 3)

        let tokenMockProvider = MockValidJWTProvider(participantName: "dave")
        let tokenContentValidator: CachingCredentialsProvider.Validator = { request, response in
            request.roomName == "test-room" && response.hasValidToken()
        }

        let tokenCachingProvider = CachingCredentialsProvider(tokenMockProvider, validator: tokenContentValidator)

        let roomRequest = ConnectionCredentials.Request(
            roomName: "test-room",
            participantName: "dave",
            participantIdentity: "dave-id"
        )

        _ = try await tokenCachingProvider.fetch(roomRequest)
        let tokenCallCount1 = await tokenMockProvider.callCount
        XCTAssertEqual(tokenCallCount1, 1)

        _ = try await tokenCachingProvider.fetch(roomRequest)
        let tokenCallCount2 = await tokenMockProvider.callCount
        XCTAssertEqual(tokenCallCount2, 1)

        let differentRoomRequest = ConnectionCredentials.Request(
            roomName: "different-room",
            participantName: "dave",
            participantIdentity: "dave-id"
        )

        _ = try await tokenCachingProvider.fetch(differentRoomRequest)
        let tokenCallCount3 = await tokenMockProvider.callCount
        XCTAssertEqual(tokenCallCount3, 2)

        _ = try await tokenCachingProvider.fetch(differentRoomRequest)
        let tokenCallCount4 = await tokenMockProvider.callCount
        XCTAssertEqual(tokenCallCount4, 3)
    }

    func testConcurrentAccess() async throws {
        let mockProvider = MockValidJWTProvider(participantName: "concurrent-test")
        let cachingProvider = CachingCredentialsProvider(mockProvider)

        let request = ConnectionCredentials.Request(
            roomName: "concurrent-room",
            participantName: "concurrent-user",
            participantIdentity: "concurrent-id"
        )

        let initialResponse = try await cachingProvider.fetch(request)
        let initialCallCount = await mockProvider.callCount
        XCTAssertEqual(initialCallCount, 1)

        async let fetch1 = cachingProvider.fetch(request)
        async let fetch2 = cachingProvider.fetch(request)
        async let fetch3 = cachingProvider.fetch(request)

        let responses = try await [fetch1, fetch2, fetch3]

        XCTAssertEqual(responses[0].participantToken, initialResponse.participantToken)
        XCTAssertEqual(responses[1].participantToken, initialResponse.participantToken)
        XCTAssertEqual(responses[2].participantToken, initialResponse.participantToken)

        XCTAssertEqual(responses[0].serverUrl, initialResponse.serverUrl)
        XCTAssertEqual(responses[1].serverUrl, initialResponse.serverUrl)
        XCTAssertEqual(responses[2].serverUrl, initialResponse.serverUrl)

        let finalCallCount = await mockProvider.callCount
        XCTAssertEqual(finalCallCount, 1)
    }
}
