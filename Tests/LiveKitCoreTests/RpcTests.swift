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
import os.lock
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
            #expect(await room.rpcClient.pendingCount == 0)
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
            #expect(await room.rpcClient.pendingCount == 0)
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
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    /// Regression test: when the destination participant disconnects mid-call, the
    /// caller receives `recipientDisconnected` (1503) immediately rather than the
    /// generic `connectionTimeout` (1501) after the user-supplied `responseTimeout`.
    /// Uses `__test_afterPublishHook` to inject the disconnect synchronously after
    /// publish so the test resolves deterministically.
    @Test func performRpcRejectsOnRecipientDisconnect() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "test-destination")
            room.publisherDataChannel = MockDataChannelPair { _ in }

            await room.rpcClient.__test_setAfterPublishHook { _ in
                await room.rpcClient.handleParticipantDisconnected(destination)
            }

            do {
                _ = try await room.localParticipant.performRpc(
                    destinationIdentity: destination,
                    method: "method",
                    payload: "x",
                    responseTimeout: 1
                )
                Issue.record("Expected RpcError, got success")
            } catch let error as RpcError {
                #expect(error.code == RpcError.BuiltInError.recipientDisconnected.code)
            }
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    /// Cancelling the Task that's awaiting `performRpc` must:
    ///   1. propagate cancellation as an error to the awaiting Task, and
    ///   2. clean up the manager's pending state so it doesn't leak.
    @Test func performRpcCleansUpOnCancellation() async throws {
        try await TestEnvironment.withRoom { room in
            // No-op data channel — the call has nothing to resolve it, so it'd otherwise
            // wait for the full responseTimeout.
            room.publisherDataChannel = MockDataChannelPair { _ in }

            let task = Task {
                try await room.localParticipant.performRpc(
                    destinationIdentity: Participant.Identity(from: "test-destination"),
                    method: "method",
                    payload: "x",
                    responseTimeout: 30
                )
            }

            // Give performRpc time to register pending state before cancelling.
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(await room.rpcClient.pendingCount == 1)

            task.cancel()

            await #expect(throws: (any Error).self) {
                _ = try await task.value
            }

            // Allow the deferred cleanup inside performRpc to run.
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    /// Five concurrent `performRpc` calls to the same destination must each get a
    /// distinct `requestId`, and after all resolve, the manager's pending maps must
    /// be empty (no leaks).
    @Test func performRpcConcurrentRequestsHaveDistinctIds() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "test-destination")
            let collector = TestStringCollector()

            let mockDataChannel = MockDataChannelPair { packet in
                guard case let .rpcRequest(request) = packet.value else { return }
                Task {
                    await collector.append(request.id)
                    await room.rpcClient.handleIncomingAck(requestId: request.id)
                    await room.rpcClient.handleIncomingResponse(
                        requestId: request.id,
                        payload: "response-\(request.id)",
                        error: nil
                    )
                }
            }
            room.publisherDataChannel = mockDataChannel

            let responses = try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0 ..< 5 {
                    group.addTask {
                        try await room.localParticipant.performRpc(
                            destinationIdentity: destination,
                            method: "method",
                            payload: "x"
                        )
                    }
                }
                var results: [String] = []
                for try await result in group {
                    results.append(result)
                }
                return results
            }

            #expect(responses.count == 5)
            let observedIds = await collector.values
            #expect(observedIds.count == 5)
            #expect(Set(observedIds).count == 5) // distinct
            #expect(await room.rpcClient.pendingCount == 0)
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

            let captured = OSAllocatedUnfairLock<Livekit_DataStream.Header?>(initialState: nil)

            try await confirmation("v2 stream opened on lk.rpc_request", expectedCount: 1) { didStartStream in
                try await confirmation("no v1 RpcRequest packet sent", expectedCount: 0) { sawRpcRequest in
                    let mockDataChannel = MockDataChannelPair { packet in
                        if case .rpcRequest = packet.value {
                            sawRpcRequest()
                            return
                        }
                        if case let .streamHeader(header) = packet.value, header.topic == RpcStreamTopic.request {
                            captured.withLock { $0 = header }
                            Task {
                                // Simulate handler ack and v2 response stream
                                let requestId = header.attributes[RpcStreamAttribute.requestId] ?? ""
                                try await Task.sleep(nanoseconds: 50_000_000)
                                await room.rpcClient.handleIncomingAck(requestId: requestId)
                                try await Task.sleep(nanoseconds: 50_000_000)
                                let reader = RpcTestSupport.makeResponseReader(requestId: requestId, payload: "v2-response")
                                await room.rpcClient.handleIncomingResponseStream(reader: reader, senderIdentity: destination)
                            }
                            didStartStream()
                        }
                    }
                    room.publisherDataChannel = mockDataChannel

                    let response = try await room.localParticipant.performRpc(
                        destinationIdentity: destination,
                        method: "v2-method",
                        payload: "small payload"
                    )
                    #expect(response == "v2-response")
                }
            }

            let header = captured.withLock { $0 }
            #expect(header?.topic == RpcStreamTopic.request)
            #expect(header?.attributes[RpcStreamAttribute.method] == "v2-method")
            #expect(header?.attributes[RpcStreamAttribute.version] == RPC_STREAM_VERSION)
            #expect(header?.attributes[RpcStreamAttribute.requestId] != nil)
            #expect(header?.attributes[RpcStreamAttribute.timeoutMs] != nil)
            #expect(await room.rpcClient.pendingCount == 0)
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
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    /// v2 handler happy path. Verifies the response is sent as a text data stream on
    /// `lk.rpc_response` (not as a `RpcResponse` packet).
    @Test func v2HandlerHappyPath() async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("v2 stream response sent", expectedCount: 1) { sawStreamHeader in
                try await confirmation("no v1 RpcResponse packet", expectedCount: 0) { sawRpcResponse in
                    let mockDataChannel = MockDataChannelPair { packet in
                        switch packet.value {
                        case let .streamHeader(header):
                            if header.topic == RpcStreamTopic.response {
                                sawStreamHeader()
                            }
                        case .rpcResponse:
                            sawRpcResponse()
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

                    // Allow async send tasks a moment to complete before the confirmation
                    // body returns and the counts are verified.
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    /// Regression test: a v2 handler returning a payload larger than the v1 packet cap
    /// (15 KB) must still send its response over the v2 data stream — the 15 KB cap is a
    /// v1 wire-format constraint, not a handler-side limit. With the cap living in
    /// `dispatchToHandler`, a 20 KB return value would be silently mapped to
    /// `responsePayloadTooLarge` and sent as a v1 error packet, which contradicts both
    /// the docstring on `dispatchToHandler` ("only applies on v1 (packet) response
    /// transports") and on `MAX_RPC_PAYLOAD_BYTES` ("v2 (data-stream-based) payloads
    /// have no size limit").
    @Test func v2HandlerCanReturnLargeResponse() async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("v2 stream response sent for large payload", expectedCount: 1) { sawStreamHeader in
                try await confirmation("no v1 RpcResponse packet", expectedCount: 0) { sawRpcResponse in
                    let mockDataChannel = MockDataChannelPair { packet in
                        switch packet.value {
                        case let .streamHeader(header):
                            if header.topic == RpcStreamTopic.response {
                                sawStreamHeader()
                            }
                        case .rpcResponse:
                            sawRpcResponse()
                        default:
                            break
                        }
                    }
                    room.publisherDataChannel = mockDataChannel

                    let largePayload = String(repeating: "y", count: 20_000)
                    try await room.registerRpcMethod("echo") { _ in largePayload }

                    let reader = RpcTestSupport.makeRequestReader(
                        requestId: "v2-req-large",
                        method: "echo",
                        payload: "go",
                        timeoutMs: 8000
                    )
                    await room.rpcServer.handleIncomingRequestStream(
                        reader: reader,
                        callerIdentity: Participant.Identity(from: "v2-caller")
                    )

                    // Allow async send tasks a moment to complete before the confirmation
                    // body returns and the counts are verified.
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
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
            #expect(await room.rpcClient.pendingCount == 0)
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
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    /// A v2 response stream from any peer other than the original RPC destination must
    /// NOT resolve the pending call — otherwise any participant could spoof responses
    /// for someone else's in-flight RPC. Pre-fix, `handleIncomingResponseStream` ignored
    /// the `senderIdentity` argument entirely and resolved on requestId match alone.
    @Test func v2ResponseStreamFromWrongSenderIsIgnored() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v2-destination")
            let imposter = Participant.Identity(from: "v2-imposter")
            try await RpcTestSupport.installV2Remote(in: room, identity: destination)

            let mockDataChannel = MockDataChannelPair { packet in
                if case let .streamHeader(header) = packet.value, header.topic == RpcStreamTopic.request {
                    let requestId = header.attributes[RpcStreamAttribute.requestId] ?? ""
                    Task {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        await room.rpcClient.handleIncomingAck(requestId: requestId)
                        // Inject a response stream from the imposter — must be ignored.
                        let reader = RpcTestSupport.makeResponseReader(requestId: requestId, payload: "spoofed")
                        await room.rpcClient.handleIncomingResponseStream(reader: reader, senderIdentity: imposter)
                    }
                }
            }
            room.publisherDataChannel = mockDataChannel

            do {
                let response = try await room.localParticipant.performRpc(
                    destinationIdentity: destination,
                    method: "method",
                    payload: "x",
                    responseTimeout: 1
                )
                Issue.record("Spoofed response from wrong sender should not have resolved the call (got \(response))")
            } catch let error as RpcError {
                // Should time out / connection-timeout since no legitimate response arrived.
                #expect(error.code == RpcError.BuiltInError.connectionTimeout.code)
            }
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    // MARK: - v2 -> v1 tests

    /// v2 caller, v1 handler: caller falls back to v1 packet path. Verifies an
    /// `RpcRequest` packet is produced with `version: 1` and no data stream is opened.
    @Test func v2CallerV1FallbackUsesPacket() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v1-destination")
            try await RpcTestSupport.installV1Remote(in: room, identity: destination)

            try await confirmation("v1 RpcRequest packet sent (version 1, matching method)", expectedCount: 1) { sawRpcRequest in
                try await confirmation("no v2 stream opened", expectedCount: 0) { sawStreamHeader in
                    let mockDataChannel = MockDataChannelPair { packet in
                        switch packet.value {
                        case let .rpcRequest(request):
                            if request.version == 1, request.method == "method" {
                                sawRpcRequest()
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
                            sawStreamHeader()
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
                }
            }
            #expect(await room.rpcClient.pendingCount == 0)
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
            #expect(await room.rpcClient.pendingCount == 0)
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

/// Async-safe append-only collector used to assert across concurrently-running tasks.
private actor TestStringCollector {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
