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

class RpcTests: LKTestCase {
    // Test performing RPC calls and verifying outgoing packets
    func testPerformRpc() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            let expectRequest = self.expectation(description: "Should send RPC request packet")

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
                expectRequest.fulfill()
            }

            room.publisherDataChannel = mockDataChannel

            let response = try await room.localParticipant.performRpc(
                destinationIdentity: Participant.Identity(from: "test-destination"),
                method: "test-method",
                payload: "test-payload"
            )

            XCTAssertEqual(response, "response-payload")
            await self.fulfillment(of: [expectRequest], timeout: 5.0)
        }
    }

    // Test registering and handling incoming RPC requests
    func testHandleIncomingRpcRequest() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            let expectResponse = self.expectation(description: "Should send RPC response packet")

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

                expectResponse.fulfill()
            }

            room.publisherDataChannel = mockDataChannel

            try await room.registerRpcMethod("greet") { data in
                "Hello, \(data.callerIdentity)!"
            }

            let isRegistered = await room.isRpcMethodRegistered("greet")
            XCTAssertTrue(isRegistered)

            do {
                try await room.registerRpcMethod("greet") { _ in "" }
                XCTFail("Duplicate RPC method registration should fail.")
            } catch {
                XCTAssertNotNil(error as? LiveKitError)
            }

            await room.localParticipant.handleIncomingRpcRequest(
                callerIdentity: Participant.Identity(from: "test-caller"),
                requestId: "test-request-1",
                method: "greet",
                payload: "Hi there!",
                responseTimeout: 8,
                version: 1
            )

            await self.fulfillment(of: [expectResponse], timeout: 5.0)
        }
    }

    // Test error handling for RPC calls
    func testRpcErrorHandling() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            let expectError = self.expectation(description: "Should send error response packet")

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

                expectError.fulfill()
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

            await self.fulfillment(of: [expectError], timeout: 5.0)
        }
    }

    // Test unregistering RPC methods
    func testUnregisterRpcMethod() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            let expectUnsupportedMethod = self.expectation(description: "Should send unsupported method error packet")

            let mockDataChannel = MockDataChannelPair { packet in
                guard case let .rpcResponse(response) = packet.value,
                      case let .error(error) = response.value
                else {
                    return
                }

                guard error.code == RpcError.BuiltInError.unsupportedMethod.code else {
                    return
                }

                expectUnsupportedMethod.fulfill()
            }

            room.publisherDataChannel = mockDataChannel

            try await room.registerRpcMethod("test") { _ in
                "test response"
            }

            await room.unregisterRpcMethod("test")

            let isRegistered = await room.isRpcMethodRegistered("test")
            XCTAssertFalse(isRegistered)

            await room.localParticipant.handleIncomingRpcRequest(
                callerIdentity: Participant.Identity(from: "test-caller"),
                requestId: "test-request-1",
                method: "test",
                payload: "test",
                responseTimeout: 10,
                version: 1
            )

            await self.fulfillment(of: [expectUnsupportedMethod], timeout: 5.0)
        }
    }
}
