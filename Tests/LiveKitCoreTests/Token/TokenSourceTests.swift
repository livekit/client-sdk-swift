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

import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import LiveKitUniFFI

struct TokenSourceTests {
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

    @Test func validJWTCaching() async throws {
        let mockSource = MockValidJWTSource(participantName: "alice")
        let cachingSource = CachingTokenSource(mockSource)

        let request = TokenRequestOptions(
            roomName: "test-room",
            participantName: "alice",
            participantIdentity: "alice-id"
        )

        let response1 = try await cachingSource.fetch(request)
        let callCount1 = await mockSource.callCount
        #expect(callCount1 == 1)
        #expect(response1.serverURL.absoluteString == "wss://test.livekit.io")
        #expect(response1.hasValidToken(), "Generated token should be valid")

        let response2 = try await cachingSource.fetch(request)
        let callCount2 = await mockSource.callCount
        #expect(callCount2 == 1)
        #expect(response2.participantToken == response1.participantToken)
        #expect(response2.serverURL == response1.serverURL)

        let differentRequest = TokenRequestOptions(
            roomName: "different-room",
            participantName: "alice",
            participantIdentity: "alice-id"
        )
        let response3 = try await cachingSource.fetch(differentRequest)
        let callCount3 = await mockSource.callCount
        #expect(callCount3 == 2)
        #expect(response3.participantToken != response1.participantToken)

        await cachingSource.invalidate()
        _ = try await cachingSource.fetch(request)
        let callCount4 = await mockSource.callCount
        #expect(callCount4 == 3)
    }

    @Test func invalidJWTHandling() async throws {
        let mockInvalidSource = MockInvalidJWTSource()
        let cachingSource = CachingTokenSource(mockInvalidSource)

        let request = TokenRequestOptions(
            roomName: "test-room",
            participantName: "bob",
            participantIdentity: "bob-id"
        )

        let response1 = try await cachingSource.fetch(request)
        let callCount1 = await mockInvalidSource.callCount
        #expect(callCount1 == 1)
        #expect(!response1.hasValidToken(), "Invalid token should not be considered valid")

        let response2 = try await cachingSource.fetch(request)
        let callCount2 = await mockInvalidSource.callCount
        #expect(callCount2 == 2)
        #expect(response2.participantToken == response1.participantToken)

        let mockExpiredSource = MockExpiredJWTSource()
        let cachingSourceExpired = CachingTokenSource(mockExpiredSource)

        let response3 = try await cachingSourceExpired.fetch(request)
        let expiredCallCount1 = await mockExpiredSource.callCount
        #expect(expiredCallCount1 == 1)
        #expect(!response3.hasValidToken(), "Expired token should not be considered valid")

        _ = try await cachingSourceExpired.fetch(request)
        let expiredCallCount2 = await mockExpiredSource.callCount
        #expect(expiredCallCount2 == 2)
    }

    // swiftlint:disable:next function_body_length
    @Test func customValidator() async throws {
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
        #expect(callCount1 == 1)
        #expect(response1.hasValidToken())

        let response2 = try await cachingSource.fetch(charlieRequest)
        let callCount2 = await mockSource.callCount
        #expect(callCount2 == 1)
        #expect(response2.participantToken == response1.participantToken)

        let aliceRequest = TokenRequestOptions(
            roomName: "test-room",
            participantName: "alice",
            participantIdentity: "alice-id"
        )

        _ = try await cachingSource.fetch(aliceRequest)
        let callCount3 = await mockSource.callCount
        #expect(callCount3 == 2)

        _ = try await cachingSource.fetch(aliceRequest)
        let callCount4 = await mockSource.callCount
        #expect(callCount4 == 3)

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
        #expect(tokenCallCount1 == 1)

        _ = try await tokenCachingSource.fetch(roomRequest)
        let tokenCallCount2 = await tokenMockSource.callCount
        #expect(tokenCallCount2 == 1)

        let differentRoomRequest = TokenRequestOptions(
            roomName: "different-room",
            participantName: "dave",
            participantIdentity: "dave-id"
        )

        _ = try await tokenCachingSource.fetch(differentRoomRequest)
        let tokenCallCount3 = await tokenMockSource.callCount
        #expect(tokenCallCount3 == 2)

        _ = try await tokenCachingSource.fetch(differentRoomRequest)
        let tokenCallCount4 = await tokenMockSource.callCount
        #expect(tokenCallCount4 == 3)
    }

    @Test func concurrentAccess() async throws {
        let mockSource = MockValidJWTSource(participantName: "concurrent-test")
        let cachingSource = CachingTokenSource(mockSource)

        let request = TokenRequestOptions(
            roomName: "concurrent-room",
            participantName: "concurrent-user",
            participantIdentity: "concurrent-id"
        )

        let initialResponse = try await cachingSource.fetch(request)
        let initialCallCount = await mockSource.callCount
        #expect(initialCallCount == 1)

        async let fetch1 = cachingSource.fetch(request)
        async let fetch2 = cachingSource.fetch(request)
        async let fetch3 = cachingSource.fetch(request)

        let responses = try await [fetch1, fetch2, fetch3]

        #expect(responses[0].participantToken == initialResponse.participantToken)
        #expect(responses[1].participantToken == initialResponse.participantToken)
        #expect(responses[2].participantToken == initialResponse.participantToken)

        #expect(responses[0].serverURL == initialResponse.serverURL)
        #expect(responses[1].serverURL == initialResponse.serverURL)
        #expect(responses[2].serverURL == initialResponse.serverURL)

        let finalCallCount = await mockSource.callCount
        #expect(finalCallCount == 1)
    }
}
