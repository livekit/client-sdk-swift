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
    // MARK: - v1 (legacy) tests

    // Test performing RPC calls and verifying outgoing packets
    @Test func performRpc() async throws {
        try await TestEnvironment.withRoom { room in
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

                    await room.rpcClient.handleIncomingAck(requestId: request.id)

                    try await Task.sleep(nanoseconds: 100_000_000)

                    await room.rpcClient.handleIncomingResponse(
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

    /// Regression test: a fast remote that responds immediately after publish must not race
    /// the caller's pending-state registration. With pre-publish registration in
    /// `RpcClientManager.performRpc`, the response arriving synchronously after `publishRequest`
    /// finds a pending entry and resolves the call. Pre-fix, registration was deferred to an
    /// inner Task that ran after publish, so a synchronously-injected response logged
    /// "received for unexpected RPC request" and the call hung to the outer timeout.
    @Test func performRpcFastRemoteResponseRace() async throws {
        try await TestEnvironment.withRoom { room in
            // No-op data channel — we drive the response via the test hook below instead of
            // the usual MockDataChannelPair callback path.
            room.publisherDataChannel = MockDataChannelPair { _ in }

            await room.rpcClient.__test_setAfterPublishHook { requestId in
                await room.rpcClient.handleIncomingAck(requestId: requestId)
                await room.rpcClient.handleIncomingResponse(
                    requestId: requestId,
                    payload: "fast-response",
                    error: nil
                )
            }

            let response = try await room.localParticipant.performRpc(
                destinationIdentity: Participant.Identity(from: "test-destination"),
                method: "test-method",
                payload: "test-payload",
                responseTimeout: 1
            )

            #expect(response == "fast-response")
        }
    }

    /// Regression test: when an RPC response arrives at roughly the same time as the
    /// 7-second ack-timeout watchdog fires, both paths attempt to resolve the same
    /// completer — the response Task with `.resume(returning:)` and the watchdog Task with
    /// `.resume(throwing: connectionTimeout)`. With the old `CheckedContinuation` this would
    /// fatalError on the second resume; with `AsyncCompleter` the second resume is a silent
    /// no-op and the first resolution wins.
    ///
    /// We use `__test_forceAckTimeout(requestId:)` to fire the watchdog synchronously
    /// instead of waiting 7 seconds. The test injects a response first, then forces the
    /// watchdog — the call must still resolve to the response payload, not
    /// `connectionTimeout`.
    @Test func performRpcResponseAndAckTimeoutDoubleResolve() async throws {
        try await TestEnvironment.withRoom { room in
            // No-op data channel — the test drives the response and watchdog via the hooks.
            room.publisherDataChannel = MockDataChannelPair { _ in }

            await room.rpcClient.__test_setAfterPublishHook { requestId in
                // Step 1: deliver the response, resolving the completer with "real-response".
                await room.rpcClient.handleIncomingResponse(
                    requestId: requestId,
                    payload: "real-response",
                    error: nil
                )
                // Step 2: force the ack-timeout watchdog. `pendingAcks` still contains
                // `requestId` (handleIncomingResponse intentionally leaves it set), so the
                // watchdog gate passes and it tries to resume the completer a second time
                // with `connectionTimeout`. Pre-fix this crashed; post-fix it's a no-op.
                await room.rpcClient.__test_forceAckTimeout(requestId: requestId)
            }

            let response = try await room.localParticipant.performRpc(
                destinationIdentity: Participant.Identity(from: "test-destination"),
                method: "test-method",
                payload: "test-payload",
                responseTimeout: 1
            )

            #expect(response == "real-response")
        }
    }

    // Test registering and handling incoming RPC requests
    @Test func handleIncomingRpcRequest() async throws {
        try await TestEnvironment.withRoom { room in
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

                await room.rpcServer.handleIncomingRequest(
                    callerIdentity: Participant.Identity(from: "test-caller"),
                    requestId: "test-request-1",
                    method: "greet",
                    payload: "Hi there!",
                    responseTimeout: 8,
                    version: 1
                )
            }
        }
    }

    // Test error handling for RPC calls
    @Test func rpcErrorHandling() async throws {
        try await TestEnvironment.withRoom { room in
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

                await room.rpcServer.handleIncomingRequest(
                    callerIdentity: Participant.Identity(from: "test-caller"),
                    requestId: "test-request-1",
                    method: "failingMethod",
                    payload: "test",
                    responseTimeout: 8,
                    version: 1
                )
            }
        }
    }

    // Test unregistering RPC methods
    @Test func unregisterRpcMethod() async throws {
        try await TestEnvironment.withRoom { room in
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

                await room.rpcServer.handleIncomingRequest(
                    callerIdentity: Participant.Identity(from: "test-caller"),
                    requestId: "test-request-1",
                    method: "test",
                    payload: "test",
                    responseTimeout: 10,
                    version: 1
                )
            }
        }
    }

    // MARK: - v2 -> v2 tests

    /// v2 caller happy path (short payload). Verifies the request is sent as a text data
    /// stream on `lk.rpc_request` (not as an `RpcRequest` packet).
    @Test func v2CallerHappyPathShort() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v2-destination")
            try await RpcTestSupport.installV2Remote(in: room, identity: destination)

            let didStartStream = AsyncFlag()
            let didSeeRpcRequestPacket = AsyncFlag()
            let captured = CapturedStreamHeader()

            let mockDataChannel = MockDataChannelPair { packet in
                if case .rpcRequest = packet.value {
                    didSeeRpcRequestPacket.set()
                    return
                }
                if case let .streamHeader(header) = packet.value, header.topic == RpcStreamTopic.request {
                    captured.set(header)
                    Task {
                        // Simulate handler ack and v2 response stream
                        let requestId = header.attributes[RpcStreamAttribute.requestId] ?? ""
                        try await Task.sleep(nanoseconds: 50_000_000)
                        await room.rpcClient.handleIncomingAck(requestId: requestId)
                        try await Task.sleep(nanoseconds: 50_000_000)
                        let reader = RpcTestSupport.makeResponseReader(requestId: requestId, payload: "v2-response")
                        await room.rpcClient.handleIncomingResponseStream(reader: reader, senderIdentity: destination)
                    }
                    didStartStream.set()
                }
            }
            room.publisherDataChannel = mockDataChannel

            let response = try await room.localParticipant.performRpc(
                destinationIdentity: destination,
                method: "v2-method",
                payload: "small payload"
            )
            #expect(response == "v2-response")
            #expect(await didStartStream.value == true)
            #expect(await didSeeRpcRequestPacket.value == false)

            let header = await captured.value
            #expect(header?.topic == RpcStreamTopic.request)
            #expect(header?.attributes[RpcStreamAttribute.method] == "v2-method")
            #expect(header?.attributes[RpcStreamAttribute.version] == RPC_STREAM_VERSION)
            #expect(header?.attributes[RpcStreamAttribute.requestId] != nil)
            #expect(header?.attributes[RpcStreamAttribute.timeoutMs] != nil)
        }
    }

    /// v2 caller happy path (large payload >15 KB). Verifies no `REQUEST_PAYLOAD_TOO_LARGE`
    /// is raised and the data stream succeeds.
    @Test func v2CallerHappyPathLargePayload() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v2-destination")
            try await RpcTestSupport.installV2Remote(in: room, identity: destination)

            let largePayload = String(repeating: "x", count: 20_000)

            let mockDataChannel = MockDataChannelPair { packet in
                if case let .streamHeader(header) = packet.value, header.topic == RpcStreamTopic.request {
                    let requestId = header.attributes[RpcStreamAttribute.requestId] ?? ""
                    Task {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        await room.rpcClient.handleIncomingAck(requestId: requestId)
                        let reader = RpcTestSupport.makeResponseReader(requestId: requestId, payload: largePayload)
                        await room.rpcClient.handleIncomingResponseStream(reader: reader, senderIdentity: destination)
                    }
                }
            }
            room.publisherDataChannel = mockDataChannel

            let response = try await room.localParticipant.performRpc(
                destinationIdentity: destination,
                method: "echo",
                payload: largePayload
            )
            #expect(response.count == largePayload.count)
        }
    }

    /// v2 handler happy path. Verifies the response is sent as a text data stream on
    /// `lk.rpc_response` (not as a `RpcResponse` packet).
    @Test func v2HandlerHappyPath() async throws {
        try await TestEnvironment.withRoom { room in
            let didSeeStreamHeader = AsyncFlag()
            let didSeeRpcResponsePacket = AsyncFlag()

            let mockDataChannel = MockDataChannelPair { packet in
                switch packet.value {
                case let .streamHeader(header):
                    if header.topic == RpcStreamTopic.response {
                        didSeeStreamHeader.set()
                    }
                case .rpcResponse:
                    didSeeRpcResponsePacket.set()
                default:
                    break
                }
            }
            room.publisherDataChannel = mockDataChannel

            try await room.registerRpcMethod("greet") { data in
                "Hello, \(data.callerIdentity)!"
            }

            let reader = RpcTestSupport.makeRequestReader(
                requestId: "v2-req-1",
                method: "greet",
                payload: "Hi!",
                timeoutMs: 8000
            )
            await room.rpcServer.handleIncomingRequestStream(
                reader: reader,
                callerIdentity: Participant.Identity(from: "v2-caller")
            )

            // Allow async send tasks a moment to complete
            try await Task.sleep(nanoseconds: 200_000_000)

            #expect(await didSeeStreamHeader.value == true)
            #expect(await didSeeRpcResponsePacket.value == false)
        }
    }

    /// Unhandled (non-RpcError) exception from a handler must be returned as a v1
    /// `RpcResponse` packet with `APPLICATION_ERROR`, even between two v2 clients.
    @Test func v2HandlerUnhandledErrorReturnsPacket() async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("Should send v1 RpcResponse packet with APPLICATION_ERROR") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          case let .error(error) = response.value,
                          error.code == RpcError.BuiltInError.applicationError.code
                    else { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                struct GenericError: Error {}
                try await room.registerRpcMethod("boom") { _ in throw GenericError() }

                let reader = RpcTestSupport.makeRequestReader(
                    requestId: "v2-req-err",
                    method: "boom",
                    payload: "",
                    timeoutMs: 8000
                )
                await room.rpcServer.handleIncomingRequestStream(
                    reader: reader,
                    callerIdentity: Participant.Identity(from: "v2-caller")
                )
            }
        }
    }

    /// `RpcError` thrown from a v2 handler must propagate to the caller via a v1
    /// `RpcResponse` packet (preserving code/message), even between two v2 clients.
    @Test func v2HandlerRpcErrorPassthroughViaPacket() async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("Should send error response packet preserving code/message") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          case let .error(error) = response.value,
                          error.code == 101,
                          error.message == "Test error message"
                    else { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                try await room.registerRpcMethod("custom") { _ in
                    throw RpcError(code: 101, message: "Test error message", data: "")
                }

                let reader = RpcTestSupport.makeRequestReader(
                    requestId: "v2-req-rpc-err",
                    method: "custom",
                    payload: "",
                    timeoutMs: 8000
                )
                await room.rpcServer.handleIncomingRequestStream(
                    reader: reader,
                    callerIdentity: Participant.Identity(from: "v2-caller")
                )
            }
        }
    }

    /// Caller times out if no ack arrives.
    @Test func v2CallerResponseTimeout() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v2-destination")
            try await RpcTestSupport.installV2Remote(in: room, identity: destination)

            // Do nothing in response — let the connection timeout (7s max round-trip) fire
            room.publisherDataChannel = MockDataChannelPair { _ in }

            await #expect(throws: RpcError.self) {
                _ = try await room.localParticipant.performRpc(
                    destinationIdentity: destination,
                    method: "method",
                    payload: "x",
                    responseTimeout: 0.05
                )
            }
        }
    }

    /// Caller v2 receives an error response (packet) from a v2 handler.
    @Test func v2CallerErrorResponse() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v2-destination")
            try await RpcTestSupport.installV2Remote(in: room, identity: destination)

            let mockDataChannel = MockDataChannelPair { packet in
                if case let .streamHeader(header) = packet.value, header.topic == RpcStreamTopic.request {
                    let requestId = header.attributes[RpcStreamAttribute.requestId] ?? ""
                    Task {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        await room.rpcClient.handleIncomingAck(requestId: requestId)
                        await room.rpcClient.handleIncomingResponse(
                            requestId: requestId,
                            payload: nil,
                            error: RpcError(code: 101, message: "Test error message", data: "")
                        )
                    }
                }
            }
            room.publisherDataChannel = mockDataChannel

            do {
                _ = try await room.localParticipant.performRpc(
                    destinationIdentity: destination,
                    method: "fails",
                    payload: "x"
                )
                Issue.record("Expected error not thrown")
            } catch let error as RpcError {
                #expect(error.code == 101)
                #expect(error.message == "Test error message")
            }
        }
    }

    // MARK: - v2 -> v1 tests

    /// v2 caller, v1 handler: caller falls back to v1 packet path. Verifies an
    /// `RpcRequest` packet is produced with `version: 1` and no data stream is opened.
    @Test func v2CallerV1FallbackUsesPacket() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v1-destination")
            try await RpcTestSupport.installV1Remote(in: room, identity: destination)

            let didSeeRpcRequest = AsyncFlag()
            let didSeeStreamHeader = AsyncFlag()

            let mockDataChannel = MockDataChannelPair { packet in
                switch packet.value {
                case let .rpcRequest(request):
                    if request.version == 1, request.method == "method" {
                        didSeeRpcRequest.set()
                        Task {
                            try await Task.sleep(nanoseconds: 50_000_000)
                            await room.rpcClient.handleIncomingAck(requestId: request.id)
                            await room.rpcClient.handleIncomingResponse(
                                requestId: request.id,
                                payload: "v1-response",
                                error: nil
                            )
                        }
                    }
                case .streamHeader:
                    didSeeStreamHeader.set()
                default:
                    break
                }
            }
            room.publisherDataChannel = mockDataChannel

            let response = try await room.localParticipant.performRpc(
                destinationIdentity: destination,
                method: "method",
                payload: "x"
            )
            #expect(response == "v1-response")
            #expect(await didSeeRpcRequest.value == true)
            #expect(await didSeeStreamHeader.value == false)
        }
    }

    /// v2 caller fallback rejects payloads >15 KB when the remote is v1.
    @Test func v2CallerV1FallbackRejectsLargePayload() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v1-destination")
            try await RpcTestSupport.installV1Remote(in: room, identity: destination)

            let largePayload = String(repeating: "x", count: 20_000)

            await #expect(throws: RpcError.self) {
                _ = try await room.localParticipant.performRpc(
                    destinationIdentity: destination,
                    method: "method",
                    payload: largePayload
                )
            }
        }
    }
}

// MARK: - Test support

private struct RpcTestSupport {
    /// Insert a remote participant into `room` whose `clientProtocol` advertises v2.
    static func installV2Remote(in room: Room, identity: Participant.Identity) async throws {
        try install(in: room, identity: identity, clientProtocol: .v1)
    }

    /// Insert a remote participant into `room` whose `clientProtocol` is v0 (legacy).
    static func installV1Remote(in room: Room, identity: Participant.Identity) async throws {
        try install(in: room, identity: identity, clientProtocol: .v0)
    }

    private static func install(in room: Room, identity: Participant.Identity, clientProtocol: ClientProtocol) throws {
        let info = Livekit_ParticipantInfo.with {
            $0.identity = identity.stringValue
            $0.sid = "PA_\(UUID().uuidString.prefix(8))"
            $0.clientProtocol = Int32(clientProtocol.rawValue)
        }
        let remote = RemoteParticipant(info: info, room: room, connectionState: .connected)
        room._state.mutate {
            $0.remoteParticipants[identity] = remote
        }
    }

    static func makeRequestReader(requestId: String, method: String, payload: String, timeoutMs: UInt32) -> TextStreamReader {
        let info = TextStreamInfo(
            id: UUID().uuidString,
            topic: RpcStreamTopic.request,
            timestamp: Date(),
            totalLength: nil,
            attributes: [
                RpcStreamAttribute.requestId: requestId,
                RpcStreamAttribute.method: method,
                RpcStreamAttribute.timeoutMs: String(timeoutMs),
                RpcStreamAttribute.version: RPC_STREAM_VERSION,
            ],
            encryptionType: .none,
            operationType: .create,
            version: 0,
            replyToStreamID: nil,
            attachedStreamIDs: [],
            generated: false
        )
        let source = StreamReaderSource { continuation in
            if let data = payload.data(using: .utf8) { continuation.yield(data) }
            continuation.finish()
        }
        return TextStreamReader(info: info, source: source)
    }

    static func makeResponseReader(requestId: String, payload: String) -> TextStreamReader {
        let info = TextStreamInfo(
            id: UUID().uuidString,
            topic: RpcStreamTopic.response,
            timestamp: Date(),
            totalLength: nil,
            attributes: [RpcStreamAttribute.requestId: requestId],
            encryptionType: .none,
            operationType: .create,
            version: 0,
            replyToStreamID: nil,
            attachedStreamIDs: [],
            generated: false
        )
        let source = StreamReaderSource { continuation in
            if let data = payload.data(using: .utf8) { continuation.yield(data) }
            continuation.finish()
        }
        return TextStreamReader(info: info, source: source)
    }
}

/// Simple async-safe boolean flag for cross-Task signaling in tests.
private actor AsyncFlag {
    private(set) var value: Bool = false
    nonisolated func set() {
        Task { await self._set() }
    }

    private func _set() { value = true }
}

private actor CapturedStreamHeader {
    private(set) var value: Livekit_DataStream.Header?
    nonisolated func set(_ header: Livekit_DataStream.Header) {
        Task { await self._set(header) }
    }

    private func _set(_ header: Livekit_DataStream.Header) { value = header }
}
