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

@Suite(.serialized, .tags(.e2e))
struct RpcTests {
    /// v2 caller happy path (short payload). Both peers advertise the current
    /// `ClientProtocol`, so the request/response flow uses v2 data streams end-to-end.
    @Test func v2CallerHappyPathShort() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let responder = rooms[0]
            let caller = rooms[1]
            let responderIdentity = try #require(responder.localParticipant.identity)

            try await responder.registerRpcMethod("v2-method") { _ in "v2-response" }

            let response = try await caller.localParticipant.performRpc(
                destinationIdentity: responderIdentity,
                method: "v2-method",
                payload: "small payload"
            )
            #expect(response == "v2-response")
            #expect(await caller.rpcClient.pendingCount == 0)
        }
    }

    /// v2 caller happy path with a payload above the v1 15 KB cap. Success through real
    /// WebRTC proves the v2 data-stream path was used — v1 packets would have been
    /// rejected with `REQUEST_PAYLOAD_TOO_LARGE`.
    @Test func v2CallerHappyPathLargePayload() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let responder = rooms[0]
            let caller = rooms[1]
            let responderIdentity = try #require(responder.localParticipant.identity)

            let largePayload = String(repeating: "x", count: 20000)
            try await responder.registerRpcMethod("echo") { data in data.payload }

            let response = try await caller.localParticipant.performRpc(
                destinationIdentity: responderIdentity,
                method: "echo",
                payload: largePayload
            )
            #expect(response == largePayload)
            #expect(await caller.rpcClient.pendingCount == 0)
        }
    }

    /// v2 handler happy path. The handler observes the real caller identity and payload
    /// from a connected peer, returns a value, and the caller receives it.
    @Test func v2HandlerHappyPath() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let responder = rooms[0]
            let caller = rooms[1]
            let responderIdentity = try #require(responder.localParticipant.identity)
            let callerIdentity = try #require(caller.localParticipant.identity)

            try await confirmation("handler invoked with the caller's identity and payload") { handlerInvoked in
                try await responder.registerRpcMethod("greet") { data in
                    #expect(data.callerIdentity == callerIdentity)
                    #expect(data.payload == "Hi!")
                    handlerInvoked()
                    return "Hello, \(data.callerIdentity)!"
                }

                let response = try await caller.localParticipant.performRpc(
                    destinationIdentity: responderIdentity,
                    method: "greet",
                    payload: "Hi!"
                )
                #expect(response == "Hello, \(callerIdentity)!")
            }
        }
    }

    /// Regression test: a v2 handler returning a payload larger than the v1 packet cap
    /// (15 KB) must still succeed — the 15 KB cap is a v1 wire-format constraint, not a
    /// handler-side limit. End-to-end success through real WebRTC proves the response
    /// went over a v2 data stream rather than being silently mapped to
    /// `responsePayloadTooLarge`.
    @Test func v2HandlerCanReturnLargeResponse() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let responder = rooms[0]
            let caller = rooms[1]
            let responderIdentity = try #require(responder.localParticipant.identity)

            let largePayload = String(repeating: "y", count: 20000)
            try await responder.registerRpcMethod("echo") { _ in largePayload }

            let response = try await caller.localParticipant.performRpc(
                destinationIdentity: responderIdentity,
                method: "echo",
                payload: "go"
            )
            #expect(response == largePayload)
            #expect(await caller.rpcClient.pendingCount == 0)
        }
    }

    /// v2 caller receives a typed error from a v2 handler that throws `RpcError`.
    @Test func v2CallerErrorResponse() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let responder = rooms[0]
            let caller = rooms[1]
            let responderIdentity = try #require(responder.localParticipant.identity)

            try await responder.registerRpcMethod("fails") { _ in
                throw RpcError(code: 101, message: "Test error message", data: "")
            }

            do {
                _ = try await caller.localParticipant.performRpc(
                    destinationIdentity: responderIdentity,
                    method: "fails",
                    payload: "x"
                )
                Issue.record("Expected error not thrown")
            } catch let error as RpcError {
                #expect(error.code == 101)
                #expect(error.message == "Test error message")
            }
            #expect(await caller.rpcClient.pendingCount == 0)
        }
    }

    /// v2 caller, v1 responder: the responder advertises `clientProtocol = .v0`, which the
    /// caller reads from `Livekit_ParticipantInfo` and uses to select the v1 packet path.
    /// If fallback didn't trigger, the caller would publish a v2 stream on `lk.rpc_request`,
    /// the v0 responder wouldn't subscribe to that topic, and the call would time out — so
    /// response arrival is the proof.
    @Test func v2CallerV1FallbackUsesPacket() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(clientProtocol: .v0, canPublishData: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let responder = rooms[0]
            let caller = rooms[1]
            let responderIdentity = try #require(responder.localParticipant.identity)

            try await responder.registerRpcMethod("method") { _ in "v1-response" }

            let response = try await caller.localParticipant.performRpc(
                destinationIdentity: responderIdentity,
                method: "method",
                payload: "x"
            )
            #expect(response == "v1-response")
            #expect(await caller.rpcClient.pendingCount == 0)
        }
    }

    /// After a caller disconnects and reconnects, v2 RPC must still route correctly.
    /// Exercises `setupRpc` idempotency: the second `connect()` re-runs `setupRpc`, and
    /// `IncomingStreamManager.registerTextStreamHandlerIfNeeded` no-ops when the v2 RPC
    /// stream handlers are still registered, so routing stays intact across reconnects.
    /// The responder is kept connected throughout so its `rpcServer.handlers` remain
    /// intact too.
    @Test func v2RpcWorksAfterReconnect() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let responder = rooms[0]
            let caller = rooms[1]
            let responderIdentity = try #require(responder.localParticipant.identity)

            try await responder.registerRpcMethod("ping") { _ in "pong" }

            let first = try await caller.localParticipant.performRpc(
                destinationIdentity: responderIdentity,
                method: "ping",
                payload: ""
            )
            #expect(first == "pong")

            // Save credentials before disconnect (cleanUp clears them on the non-reconnect path).
            let url = try #require(caller.url)
            let token = try #require(caller.token)
            await caller.disconnect()
            try await caller.connect(url: url, token: token)

            // Wait for caller to rediscover responder after reconnect, otherwise
            // `performRpc` reads `remoteParticipants[…]?.clientProtocol = nil` and
            // falls back to the v1 packet path instead of exercising v2.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, caller.remoteParticipants[responderIdentity] == nil {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try #require(caller.remoteParticipants[responderIdentity] != nil,
                         "responder did not reappear after caller reconnect")

            let second = try await caller.localParticipant.performRpc(
                destinationIdentity: responderIdentity,
                method: "ping",
                payload: ""
            )
            #expect(second == "pong")
            #expect(await caller.rpcClient.pendingCount == 0)
        }
    }

    /// v2 caller falling back to the v1 path rejects payloads >15 KB before publishing.
    @Test func v2CallerV1FallbackRejectsLargePayload() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(clientProtocol: .v0, canPublishData: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let responder = rooms[0]
            let caller = rooms[1]
            let responderIdentity = try #require(responder.localParticipant.identity)

            let largePayload = String(repeating: "x", count: 20000)

            await #expect(throws: RpcError.self) {
                _ = try await caller.localParticipant.performRpc(
                    destinationIdentity: responderIdentity,
                    method: "method",
                    payload: largePayload
                )
            }
            #expect(await caller.rpcClient.pendingCount == 0)
        }
    }
}
