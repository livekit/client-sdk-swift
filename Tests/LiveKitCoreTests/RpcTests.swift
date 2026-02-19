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

@Suite(.tags(.e2e))
struct RpcTests {
    // Test performing RPC calls and verifying outgoing packets
    @Test func performRpc() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            let mockDataChannel = MockDataChannelPair { packet in
                guard case let .rpcRequest(request) = packet.value else {
                    print("Not an RPC request packet")
                    return
                }

                guard request.method == "test-method", request.payload == "test-payload", request.responseTimeoutMs == 8000 else {
                    return
                }

                // Trigger fake response packets
                Task {
                    try await Task.sleep(nanoseconds: 100_000_000)

                    room.localParticipant.handleIncomingRpcAck(requestId: request.id)

                    try await Task.sleep(nanoseconds: 100_000_000)

                    room.localParticipant.handleIncomingRpcResponse(
                        requestId: request.id,
                        payload: "response-payload",
                        error: nil
                    )
                }
            }

            room.publisherDataChannel = mockDataChannel

            let response = try await room.localParticipant.performRpc(
                destinationIdentity: Participant.Identity(from: "test-destination"),
                method: "test-method",
                payload: "test-payload"
            )

            #expect(response == "response-payload")
        }
    }

    // Test registering and handling incoming RPC requests
    @Test func handleIncomingRpcRequest() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            try await confirmation("Should send RPC response packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value else {
                        return
                    }

                    guard case let .payload(payload) = response.value else {
                        return
                    }

                    guard response.requestID == "test-request-1",
                          payload == "Hello, test-caller!"
                    else {
                        return
                    }

                    confirm()
                }

                room.publisherDataChannel = mockDataChannel

                try await room.registerRpcMethod("greet") { data in
                    "Hello, \(data.callerIdentity)!"
                }

                let isRegistered = await room.isRpcMethodRegistered("greet")
                #expect(isRegistered)

                do {
                    try await room.registerRpcMethod("greet") { _ in "" }
                    Issue.record("Duplicate RPC method registration should fail.")
                } catch {
                    #expect(error is LiveKitError)
                }

                await room.localParticipant.handleIncomingRpcRequest(
                    callerIdentity: Participant.Identity(from: "test-caller"),
                    requestId: "test-request-1",
                    method: "greet",
                    payload: "Hi there!",
                    responseTimeout: 8,
                    version: 1
                )

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // Test error handling for RPC calls
    @Test func rpcErrorHandling() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            try await confirmation("Should send error response packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          case let .error(error) = response.value
                    else {
                        return
                    }

                    guard error.code == 2000,
                          error.message == "Custom error",
                          error.data == "Additional data"
                    else {
                        return
                    }

                    confirm()
                }

                room.publisherDataChannel = mockDataChannel

                try await room.registerRpcMethod("failingMethod") { _ in
                    throw RpcError(code: 2000, message: "Custom error", data: "Additional data")
                }

                await room.localParticipant.handleIncomingRpcRequest(
                    callerIdentity: Participant.Identity(from: "test-caller"),
                    requestId: "test-request-1",
                    method: "failingMethod",
                    payload: "test",
                    responseTimeout: 8,
                    version: 1
                )

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // Test unregistering RPC methods
    @Test func unregisterRpcMethod() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            try await confirmation("Should send unsupported method error packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          case let .error(error) = response.value
                    else {
                        return
                    }

                    guard error.code == RpcError.BuiltInError.unsupportedMethod.code else {
                        return
                    }

                    confirm()
                }

                room.publisherDataChannel = mockDataChannel

                try await room.registerRpcMethod("test") { _ in
                    "test response"
                }

                await room.unregisterRpcMethod("test")

                let isRegistered = await room.isRpcMethodRegistered("test")
                #expect(!isRegistered)

                await room.localParticipant.handleIncomingRpcRequest(
                    callerIdentity: Participant.Identity(from: "test-caller"),
                    requestId: "test-request-1",
                    method: "test",
                    payload: "test",
                    responseTimeout: 10,
                    version: 1
                )

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}
