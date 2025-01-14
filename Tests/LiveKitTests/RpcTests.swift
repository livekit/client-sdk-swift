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

@testable import LiveKit
import XCTest

class RpcTests: XCTestCase {
    
    // Mock DataChannelPair to intercept outgoing packets
    class MockDataChannelPair: DataChannelPair {
        var expectation: XCTestExpectation
        var expectedPacketHandler: ((Livekit_DataPacket) -> Bool)?
        
        init(expectation: XCTestExpectation) {
            self.expectation = expectation
            super.init()
        }
        
        override func send(dataPacket packet: Livekit_DataPacket) throws {
            if let handler = expectedPacketHandler, handler(packet) {
                expectation.fulfill()
            }
            try super.send(dataPacket: packet)
        }
    }
    
    // Test performing RPC calls and verifying outgoing packets
    func testPerformRpc() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            
            // Create expectation for outgoing RPC request packet
            let expectRequest = self.expectation(description: "Should send RPC request packet")

            // Create mock data channel
            let mockDataChannel = MockDataChannelPair(expectation: expectRequest)
            mockDataChannel.expectedPacketHandler = { packet in
                // Verify it's an RPC request packet
                guard case .rpcRequest(let request) = packet.value else {
                    return false
                }
                
                // Verify request content
                return request.method == "test-method" &&
                       request.payload == "test-payload" &&
                       request.responseTimeoutMs == 10_000 // 10 seconds
            }
            
            // Replace the publisher data channel with our mock
            room.publisherDataChannel = mockDataChannel
            
            let destinationIdentity = Participant.Identity(from: "test-destination")
            let method = "test-method"
            let payload = "test-payload"
            
            // Create a task to simulate receiving response
            Task {
                // Wait a bit to ensure RPC call is made
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                
                // Simulate receiving RPC ack
                room.localParticipant.handleIncomingRpcAck(requestId: "test-request")
                
                // Simulate receiving RPC response
                room.localParticipant.handleIncomingRpcResponse(
                    requestId: "test-request",
                    payload: "response-payload",
                    error: nil
                )
            }
            
            // Perform the RPC call
            let response = try await room.localParticipant.performRpc(
                destinationIdentity: destinationIdentity,
                method: method,
                payload: payload
            )
            
            XCTAssertEqual(response, "response-payload")
            await self.fulfillment(of: [expectRequest], timeout: 5.0)
        }
    }
    
    // Test registering and handling incoming RPC requests
    func testHandleIncomingRpcRequest() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            
            // Create expectation for outgoing RPC response packet
            let expectResponse = self.expectation(description: "Should send RPC response packet")

            // Create mock data channel
            let mockDataChannel = MockDataChannelPair(expectation: expectResponse)
            mockDataChannel.expectedPacketHandler = { packet in
                // Verify it's an RPC response packet
                guard case .rpcResponse(let response) = packet.value else {
                    return false
                }
                
                // Verify response content
                guard case .payload(let payload) = response.value else {
                    return false
                }
                
                return response.requestID == "test-request-1" &&
                       payload == "Hello, test-caller!"
            }
            
            // Replace the publisher data channel with our mock
            room.publisherDataChannel = mockDataChannel
            
            // Register a method
            await room.localParticipant.registerRpcMethod("greet") { data in
                return "Hello, \(data.callerIdentity)!"
            }
            
            // Simulate an incoming RPC request
            let callerIdentity = Participant.Identity(from: "test-caller")
            let requestId = "test-request-1"
            let method = "greet"
            let payload = "Hi there!"
            let responseTimeout: TimeInterval = 10
            let version = 1
            
            // Simulate the RPC request
            await room.localParticipant.handleIncomingRpcRequest(
                callerIdentity: callerIdentity,
                requestId: requestId,
                method: method,
                payload: payload,
                responseTimeout: responseTimeout,
                version: version
            )
            
            await self.fulfillment(of: [expectResponse], timeout: 5.0)
        }
    }
    
    // Test error handling for RPC calls
    func testRpcErrorHandling() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            
            // Create expectation for error response packet
            let expectError = self.expectation(description: "Should send error response packet")

            // Create mock data channel
            let mockDataChannel = MockDataChannelPair(expectation: expectError)
            mockDataChannel.expectedPacketHandler = { packet in
                // Verify it's an RPC response packet with error
                guard case .rpcResponse(let response) = packet.value,
                      case .error(let error) = response.value else {
                    return false
                }
                
                // Verify error content
                return error.code == 2000 &&
                       error.message == "Custom error" &&
                       error.data == "Additional data"
            }
            
            // Replace the publisher data channel with our mock
            room.publisherDataChannel = mockDataChannel
            
            // Register method that throws error
            await room.localParticipant.registerRpcMethod("failingMethod") { _ in
                throw RpcError(code: 2000, message: "Custom error", data: "Additional data")
            }
            
            // Simulate incoming RPC request that should trigger error
            let callerIdentity = Participant.Identity(from: "test-caller")
            let requestId = "test-request-1"
            let method = "failingMethod"
            let payload = "test"
            let responseTimeout: TimeInterval = 10
            let version = 1
            
            // Simulate the RPC request
            await room.localParticipant.handleIncomingRpcRequest(
                callerIdentity: callerIdentity,
                requestId: requestId,
                method: method,
                payload: payload,
                responseTimeout: responseTimeout,
                version: version
            )
            
            await self.fulfillment(of: [expectError], timeout: 5.0)
        }
    }
    
    // Test unregistering RPC methods
    func testUnregisterRpcMethod() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            
            // Create expectation for unsupported method error packet
            let expectUnsupportedMethod = self.expectation(description: "Should send unsupported method error packet")

            // Create mock data channel
            let mockDataChannel = MockDataChannelPair(expectation: expectUnsupportedMethod)
            mockDataChannel.expectedPacketHandler = { packet in
                // Verify it's an RPC response packet with unsupported method error
                guard case .rpcResponse(let response) = packet.value,
                      case .error(let error) = response.value else {
                    return false
                }
                
                // Verify error content
                return error.code == RpcError.BuiltInError.unsupportedMethod.code
            }
            
            // Replace the publisher data channel with our mock
            room.publisherDataChannel = mockDataChannel
            
            // Register a method
            await room.localParticipant.registerRpcMethod("test") { _ in
                return "test response"
            }
            
            // Unregister the method
            await room.localParticipant.unregisterRpcMethod("test")
            
            // Simulate an RPC request to the unregistered method
            let callerIdentity = Participant.Identity(from: "test-caller")
            let requestId = "test-request-1"
            let method = "test"
            let payload = "test"
            let responseTimeout: TimeInterval = 10
            let version = 1
            
            // Simulate the RPC request
            await room.localParticipant.handleIncomingRpcRequest(
                callerIdentity: callerIdentity,
                requestId: requestId,
                method: method,
                payload: payload,
                responseTimeout: responseTimeout,
                version: version
            )
            
            await self.fulfillment(of: [expectUnsupportedMethod], timeout: 5.0)
        }
    }
} 
