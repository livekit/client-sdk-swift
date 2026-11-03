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
import Testing

struct RpcV1ResponseSenderTests {
    private static let callee = Participant.Identity(from: "callee")
    private static let other = Participant.Identity(from: "other")

    @Test func responseFromCalleeCompletesCall() async throws {
        let response = try await performRpc { client, requestId in
            await client.handleIncomingResponse(requestId: requestId, payload: "response", error: nil, senderIdentity: Self.callee)
        }
        #expect(response == "response")
    }

    @Test(arguments: [nil, RpcError(code: 101, message: "other error", data: "")] as [RpcError?])
    func responseFromWrongSenderIsIgnored(error: RpcError?) async throws {
        let response = try await performRpc { client, requestId in
            await client.handleIncomingResponse(requestId: requestId, payload: "other response", error: error, senderIdentity: Self.other)
            #expect(await client.pendingResponses[requestId]?.participantIdentity == Self.callee)
            #expect(await client.pendingAcks[requestId] == Self.callee)
            await client.handleIncomingResponse(requestId: requestId, payload: "response", error: nil, senderIdentity: Self.callee)
        }
        #expect(response == "response")
    }

    @Test func ackFromCalleeStopsAckTimeout() async throws {
        let response = try await performRpc { client, requestId in
            await client.handleIncomingAck(requestId: requestId, senderIdentity: Self.callee)
            #expect(await client.pendingAcks[requestId] == nil)
            await client.fireAckTimeoutIfPending(requestId: requestId)
            #expect(await client.pendingCount == 1)
            await client.handleIncomingResponse(requestId: requestId, payload: "response", error: nil, senderIdentity: Self.callee)
        }
        #expect(response == "response")
    }

    @Test func ackFromWrongSenderIsIgnoredUntilCalleeAck() async throws {
        let response = try await performRpc { client, requestId in
            await client.handleIncomingAck(requestId: requestId, senderIdentity: Self.other)
            #expect(await client.pendingAcks[requestId] == Self.callee)
            await client.handleIncomingAck(requestId: requestId, senderIdentity: Self.callee)
            #expect(await client.pendingAcks[requestId] == nil)
            await client.fireAckTimeoutIfPending(requestId: requestId)
            #expect(await client.pendingCount == 1)
            await client.handleIncomingResponse(requestId: requestId, payload: "response", error: nil, senderIdentity: Self.callee)
        }
        #expect(response == "response")
    }

    @Test func ackFromWrongSenderDoesNotStopAckTimeout() async throws {
        let error = try #require(await #expect(throws: RpcError.self) {
            try await performRpc { client, requestId in
                await client.handleIncomingAck(requestId: requestId, senderIdentity: Self.other)
                #expect(await client.pendingAcks[requestId] == Self.callee)
                await client.fireAckTimeoutIfPending(requestId: requestId)
                #expect(await client.pendingCount == 0)
            }
        })
        #expect(error.code == RpcError.BuiltInError.connectionTimeout.code)
    }

    private func performRpc(afterPublish: @escaping @Sendable (RpcClientManager, String) async -> Void) async throws -> String {
        let room = Room()
        let client = room.rpcClient
        await client.attach(to: room)
        room.publisherDataChannel = MockDataChannelPair { _ in }
        room._state.mutate { $0.connectionState = .connected }
        await client.setAfterPublish { [weak client] requestId in
            guard let client else { return }
            await afterPublish(client, requestId)
        }
        let response = try await client.performRpc(destinationIdentity: Self.callee, method: "method", payload: "request", responseTimeout: 5)
        #expect(await room.rpcClient.pendingResponses.isEmpty)
        #expect(await room.rpcClient.pendingAcks.isEmpty)
        #expect(await room.rpcClient.ackWatchdogs.isEmpty)
        return response
    }
}
