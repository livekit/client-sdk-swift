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

// swiftlint:disable file_length type_body_length

// MARK: - RpcClientTests

/// Unit-level coverage of ``RpcClientManager``: caller-side state machine,
/// pending bookkeeping, timeout codes, cancellation, and sender validation.
@Suite(.serialized, .tags(.e2e, .rpc))
struct RpcClientTests {
    // MARK: - v1 caller-side state machine

    @Test func performRpc() async throws {
        try await TestEnvironment.withRoom { room in
            let mockDataChannel = MockDataChannelPair { packet in
                guard case let .rpcRequest(request) = packet.value else { return }
                guard request.method == "test-method",
                      request.payload == "test-payload",
                      request.responseTimeoutMs == 15000
                else { return }

                // Pre-registration in performRpc is synchronous on the actor before
                // publish, so the ack/response can fire immediately without a sleep.
                Task {
                    await room.rpcClient.handleIncomingAck(requestId: request.id)
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

    /// Regression test: a fast remote that responds immediately after publish must not
    /// race the caller's pending-state registration. With pre-publish registration in
    /// `RpcClientManager.performRpc`, the response arriving synchronously after
    /// `publishRequest` finds a pending entry and resolves the call. Pre-fix,
    /// registration was deferred to an inner Task that ran after publish, so a
    /// synchronously-injected response logged "received for unexpected RPC request" and
    /// the call hung to the outer timeout.
    @Test func performRpcFastRemoteResponseRace() async throws {
        try await TestEnvironment.withRoom { room in
            room.publisherDataChannel = MockDataChannelPair { _ in }

            await room.rpcClient.setAfterPublish { requestId in
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
    /// completer — the response Task with `.resume(returning:)` and the watchdog with
    /// `.resume(throwing: connectionTimeout)`. With the old `CheckedContinuation` this
    /// fatalError'd on the second resume; with `AsyncCompleter` the second resume is a
    /// silent no-op and the first resolution wins.
    ///
    /// Uses `fireAckTimeoutIfPending(requestId:)` to fire the watchdog synchronously
    /// instead of waiting 7 seconds. The test injects a response first, then forces
    /// the watchdog — the call must still resolve to the response payload, not
    /// `connectionTimeout`.
    @Test func performRpcResponseAndAckTimeoutDoubleResolve() async throws {
        try await TestEnvironment.withRoom { room in
            room.publisherDataChannel = MockDataChannelPair { _ in }

            await room.rpcClient.setAfterPublish { requestId in
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
                await room.rpcClient.fireAckTimeoutIfPending(requestId: requestId)
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
    /// This v2→v1 variant uses an uninstalled destination so the caller picks the
    /// v1 packet transport.
    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L302"))
    func performRpcRejectsOnRecipientDisconnect() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "test-destination")
            room.publisherDataChannel = MockDataChannelPair { _ in }

            await room.rpcClient.setAfterPublish { _ in
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

    /// v2→v2 variant of the disconnect-mid-call regression: with a v2-capable
    /// destination installed the caller picks the v2 stream transport, but the
    /// disconnect-reaping path is transport-agnostic so the result is still
    /// `recipientDisconnected` (1503).
    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L258"))
    func performRpcRejectsOnV2RecipientDisconnect() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v2-destination")
            try await RpcTestSupport.installRemote(in: room, identity: destination, clientProtocol: .v1)
            room.publisherDataChannel = MockDataChannelPair { _ in }

            await room.rpcClient.setAfterPublish { _ in
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
            room.publisherDataChannel = MockDataChannelPair { _ in }

            // Signal when performRpc has pre-registered pending state, instead of
            // polling/sleeping.
            let registered = AsyncCompleter<Void>(label: "performRpc-registered", defaultTimeout: 5)
            await room.rpcClient.setAfterPublish { _ in
                registered.resume(returning: ())
            }

            let task = Task {
                try await room.localParticipant.performRpc(
                    destinationIdentity: Participant.Identity(from: "test-destination"),
                    method: "method",
                    payload: "x",
                    responseTimeout: 30
                )
            }

            try await registered.wait()
            #expect(await room.rpcClient.pendingCount == 1)

            task.cancel()

            await #expect(throws: (any Error).self) {
                _ = try await task.value
            }

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

    // MARK: - v2 caller-side wire-format & state-machine internals

    /// Caller times out waiting for the response. With `responseTimeout < maxRoundTripLatency`,
    /// the completer's `defaultTimeout` fires before the ack-watchdog and surfaces as
    /// `responseTimeout` (1502) — `connectionTimeout` (1501) is reserved for the
    /// ack-watchdog path.
    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L247"))
    func v2CallerResponseTimeout() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v2-destination")
            try await RpcTestSupport.installRemote(in: room, identity: destination, clientProtocol: .v1)

            room.publisherDataChannel = MockDataChannelPair { _ in }

            do {
                _ = try await room.localParticipant.performRpc(
                    destinationIdentity: destination,
                    method: "method",
                    payload: "x",
                    responseTimeout: 0.05
                )
                Issue.record("Expected RpcError to be thrown")
            } catch let error as RpcError {
                #expect(error.code == RpcError.BuiltInError.responseTimeout.code)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    /// v2→v1 variant of response timeout: with a v0 destination installed the
    /// caller picks the v1 packet transport. No ack/response arrives, completer
    /// `defaultTimeout` expires → `responseTimeout` (1502).
    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L289"))
    func v2CallerV1FallbackResponseTimeout() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v1-destination")
            try await RpcTestSupport.installRemote(in: room, identity: destination, clientProtocol: .v0)

            room.publisherDataChannel = MockDataChannelPair { _ in }

            do {
                _ = try await room.localParticipant.performRpc(
                    destinationIdentity: destination,
                    method: "method",
                    payload: "x",
                    responseTimeout: 0.05
                )
                Issue.record("Expected RpcError to be thrown")
            } catch let error as RpcError {
                #expect(error.code == RpcError.BuiltInError.responseTimeout.code)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    /// v2→v1 variant of the typed-error round-trip: v0 destination → v1 packet
    /// transport, mocked channel injects ack + error `RpcResponse` packet. The
    /// caller rejects with the original error code/message.
    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L295"))
    func v2CallerV1FallbackErrorResponse() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v1-destination")
            try await RpcTestSupport.installRemote(in: room, identity: destination, clientProtocol: .v0)

            let mockDataChannel = MockDataChannelPair { packet in
                guard case let .rpcRequest(request) = packet.value else { return }
                Task {
                    await room.rpcClient.handleIncomingAck(requestId: request.id)
                    await room.rpcClient.handleIncomingResponse(
                        requestId: request.id,
                        payload: nil,
                        error: RpcError(code: 101, message: "Test error message", data: "")
                    )
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

    /// `handleIncomingResponse` with a `requestId` that isn't in `pendingResponses`
    /// must log and no-op (e.g. a late response after the call already resolved or
    /// was reaped). Verifies it doesn't crash or mutate state.
    @Test func responsePacketForUnknownRequestIdIsIgnored() async throws {
        try await TestEnvironment.withRoom { room in
            await room.rpcClient.handleIncomingResponse(
                requestId: "no-such-request",
                payload: "ignored",
                error: nil
            )
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    /// A v2 response stream without an `lk.rpc_request_id` attribute can't be
    /// correlated to any pending call. `handleIncomingResponseStream` must log
    /// and bail without mutating state.
    @Test func responseStreamMissingRequestIdIsIgnored() async throws {
        try await TestEnvironment.withRoom { room in
            let reader = RpcTestSupport.makeResponseReader(requestId: nil, payload: "ignored")
            await room.rpcClient.handleIncomingResponseStream(
                reader: reader,
                senderIdentity: Participant.Identity(from: "anyone")
            )
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }

    /// When the v2 response-stream reader fails partway through (e.g. peer-closed
    /// transport mid-stream), the pending call must be failed fast with
    /// `APPLICATION_ERROR` instead of hanging to `responseTimeout`. Matches the
    /// JS-parity fix in `RpcClientManager.handleIncomingResponseStream`.
    @Test func v2ResponseStreamReaderFailureFailsPending() async throws {
        try await TestEnvironment.withRoom { room in
            let destination = Participant.Identity(from: "v2-destination")
            try await RpcTestSupport.installRemote(in: room, identity: destination, clientProtocol: .v1)

            let mockDataChannel = MockDataChannelPair { packet in
                if case let .streamHeader(header) = packet.value, header.topic == RpcStreamTopic.request {
                    Task {
                        let requestId = try #require(header.attributes[RpcStreamAttribute.requestId])
                        await room.rpcClient.handleIncomingAck(requestId: requestId)
                        let reader = RpcTestSupport.makeFailingResponseReader(requestId: requestId)
                        await room.rpcClient.handleIncomingResponseStream(reader: reader, senderIdentity: destination)
                    }
                }
            }
            room.publisherDataChannel = mockDataChannel

            do {
                _ = try await room.localParticipant.performRpc(
                    destinationIdentity: destination,
                    method: "method",
                    payload: "x",
                    responseTimeout: 10
                )
                Issue.record("Expected APPLICATION_ERROR from failed response reader")
            } catch let error as RpcError {
                #expect(error.code == RpcError.BuiltInError.applicationError.code)
                #expect(error.message == "Error reading RPC response payload")
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
            try await RpcTestSupport.installRemote(in: room, identity: destination, clientProtocol: .v1)

            let mockDataChannel = MockDataChannelPair { packet in
                if case let .streamHeader(header) = packet.value, header.topic == RpcStreamTopic.request {
                    Task {
                        let requestId = try #require(header.attributes[RpcStreamAttribute.requestId])
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
                // Ack arrived (legitimately) but the spoofed response was ignored, so the
                // completer's user-supplied `responseTimeout` (1s) elapses → 1502.
                #expect(error.code == RpcError.BuiltInError.responseTimeout.code)
            }
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }
}

// MARK: - RpcServerTests

/// Unit-level coverage of ``RpcServerManager``: handler registry, v1 dispatch,
/// v2 stream dispatch error paths.
@Suite(.serialized, .tags(.e2e, .rpc))
struct RpcServerTests {
    // MARK: - v1 server-side handler dispatch

    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L274"))
    func handleIncomingRpcRequest() async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("Should send RPC response packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          case let .payload(payload) = response.value,
                          response.requestID == "test-request-1",
                          payload == "Hello, test-caller!"
                    else { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                try await room.registerRpcMethod("greet") { data in
                    "Hello, \(data.callerIdentity)!"
                }

                let isRegistered = await room.isRpcMethodRegistered("greet")
                #expect(isRegistered)

                await #expect(throws: LiveKitError.self) {
                    try await room.registerRpcMethod("greet") { _ in "" }
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

    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L324"))
    func rpcErrorHandling() async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("Should send error response packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          case let .error(error) = response.value,
                          error.code == 2000,
                          error.message == "Custom error",
                          error.data == "Additional data"
                    else { return }
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

    /// v1 caller → v2 handler, unhandled error variant: a registered method throws
    /// a non-`RpcError` exception. The handler wraps it as `APPLICATION_ERROR`
    /// (1500) and publishes a v1 `RpcResponse` packet (caller is `clientProtocol = 0`
    /// per the default, so `publishResult` picks the v1 packet response transport).
    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L318"))
    func v1HandlerUnhandledErrorReturnsPacket() async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("Sends APPLICATION_ERROR packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          response.requestID == "v1-unhandled",
                          case let .error(error) = response.value,
                          error.code == RpcError.BuiltInError.applicationError.code
                    else { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                try await room.registerRpcMethod("error-method") { _ in
                    throw GenericTestError()
                }

                await room.rpcServer.handleIncomingRequest(
                    callerIdentity: Participant.Identity(from: "v1-caller"),
                    requestId: "v1-unhandled",
                    method: "error-method",
                    payload: "",
                    responseTimeout: 8,
                    version: 1
                )
            }
        }
    }

    @Test func unregisterRpcMethod() async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("Should send unsupported method error packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          case let .error(error) = response.value,
                          error.code == RpcError.BuiltInError.unsupportedMethod.code
                    else { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                try await room.registerRpcMethod("test") { _ in "test response" }
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

    /// A v1 handler returning a payload above `MAX_RPC_PAYLOAD_BYTES` (15 KB)
    /// must publish a `responsePayloadTooLarge` (1504) error packet instead of
    /// emitting an oversize payload over the v1 wire. The v2 stream path has
    /// no such cap (`v2HandlerCanReturnLargeResponse` covers that side).
    @Test func v1HandlerOversizeResponseReturnsTooLargePacket() async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("Sends responsePayloadTooLarge error packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          response.requestID == "v1-oversize",
                          case let .error(error) = response.value,
                          error.code == RpcError.BuiltInError.responsePayloadTooLarge.code
                    else { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                let oversize = String(repeating: "y", count: MAX_RPC_PAYLOAD_BYTES + 1)
                try await room.registerRpcMethod("big") { _ in oversize }

                await room.rpcServer.handleIncomingRequest(
                    callerIdentity: Participant.Identity(from: "v1-caller"),
                    requestId: "v1-oversize",
                    method: "big",
                    payload: "",
                    responseTimeout: 8,
                    version: 1
                )
            }
        }
    }

    /// Spec test case #16 (v1 → v2 handler response fallback): a legacy v1 caller
    /// (`clientProtocol = .v0`) sends a v1 `RpcRequest` packet to a v2-capable
    /// handler. Even though the handler supports v2 streams, it must respond
    /// with a v1 `RpcResponse` packet — not a stream — because the caller
    /// doesn't subscribe to `lk.rpc_response`. Pins the per-caller transport
    /// selection in `publishResult`.
    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L310"))
    func v1CallerToV2HandlerResponseUsesV1Packet() async throws {
        try await TestEnvironment.withRoom { room in
            let v1Caller = Participant.Identity(from: "legacy-v1-caller")
            try await RpcTestSupport.installRemote(in: room, identity: v1Caller, clientProtocol: .v0)

            try await confirmation("Response arrives as v1 RpcResponse packet, not a stream") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    if case let .streamHeader(header) = packet.value, header.topic == RpcStreamTopic.response {
                        Issue.record("v2 stream response opened for v1 caller (\(header.attributes))")
                        return
                    }
                    guard case let .rpcResponse(response) = packet.value,
                          response.requestID == "v1-to-v2",
                          case let .payload(payload) = response.value,
                          payload == "v1-response"
                    else { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                try await room.registerRpcMethod("ping") { _ in "v1-response" }

                await room.rpcServer.handleIncomingRequest(
                    callerIdentity: v1Caller,
                    requestId: "v1-to-v2",
                    method: "ping",
                    payload: "",
                    responseTimeout: 8,
                    version: 1
                )
            }
        }
    }

    /// A v1 `RpcRequest` packet with `version != 1` must respond with
    /// `unsupportedVersion` (1404) — pinning the JS-parity behavior in the v1
    /// path of `RpcServerManager.handleIncomingRequest`.
    @Test func v1HandleIncomingRequestUnsupportedVersion() async throws {
        try await TestEnvironment.withRoom { room in
            await confirmation("Sends unsupportedVersion error packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          case let .error(error) = response.value,
                          error.code == RpcError.BuiltInError.unsupportedVersion.code
                    else { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                await room.rpcServer.handleIncomingRequest(
                    callerIdentity: Participant.Identity(from: "v1-caller"),
                    requestId: "v1-bad-version",
                    method: "anything",
                    payload: "",
                    responseTimeout: 8,
                    version: 2
                )
            }
        }
    }

    // MARK: - v2 server-side wire-format & state-machine internals

    enum HandlerErrorScenario: CaseIterable, CustomTestStringConvertible {
        case genericError
        case rpcErrorPassthrough

        var testDescription: String {
            switch self {
            case .genericError: "generic Error → APPLICATION_ERROR"
            case .rpcErrorPassthrough: "RpcError → preserved code/message"
            }
        }

        var expectedCode: Int {
            switch self {
            case .genericError: RpcError.BuiltInError.applicationError.code
            case .rpcErrorPassthrough: 101
            }
        }

        /// `nil` means "don't assert on message" (generic errors don't carry through).
        var expectedMessage: String? {
            switch self {
            case .genericError: nil
            case .rpcErrorPassthrough: "Test error message"
            }
        }
    }

    private struct GenericTestError: Error {}

    /// v2 handler errors are always returned as v1 `RpcResponse` packets per spec,
    /// regardless of caller transport. Generic `Error` → `APPLICATION_ERROR` (1500);
    /// thrown `RpcError` → original code/message preserved.
    /// v2 stream missing the `lk.rpc_request_id` attribute can't be correlated to a
    /// reply, so the handler must log and bail — never publish a packet.
    @Test func v2RequestStreamMissingRequestIdIsSilent() async throws {
        try await TestEnvironment.withRoom { room in
            await confirmation("No packet sent", expectedCount: 0) { confirm in
                room.publisherDataChannel = MockDataChannelPair { _ in confirm() }

                let reader = RpcTestSupport.makeRequestReader(
                    requestId: nil,
                    method: "anything",
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

    enum V2RequestErrorScenario: CaseIterable, CustomTestStringConvertible {
        case missingMethod
        case wrongVersion
        case readerFailure

        var testDescription: String {
            switch self {
            case .missingMethod: "missing `method` attr → APPLICATION_ERROR/malformed"
            case .wrongVersion: "version='3' → unsupportedVersion"
            case .readerFailure: "reader.readAll() throws → APPLICATION_ERROR/read-failure"
            }
        }

        var requestId: String {
            switch self {
            case .missingMethod: "v2-req-incomplete"
            case .wrongVersion: "v2-req-badver"
            case .readerFailure: "v2-req-readfail"
            }
        }

        func makeReader() -> TextStreamReader {
            switch self {
            case .missingMethod:
                RpcTestSupport.makeRequestReader(
                    requestId: requestId, method: nil, payload: "", timeoutMs: 8000
                )
            case .wrongVersion:
                RpcTestSupport.makeRequestReader(
                    requestId: requestId, method: "anything", payload: "", timeoutMs: 8000, version: "3"
                )
            case .readerFailure:
                RpcTestSupport.makeFailingRequestReader(
                    requestId: requestId, method: "anything", timeoutMs: 8000
                )
            }
        }

        var expectedCode: Int {
            switch self {
            case .missingMethod, .readerFailure: RpcError.BuiltInError.applicationError.code
            case .wrongVersion: RpcError.BuiltInError.unsupportedVersion.code
            }
        }

        /// `nil` means "don't assert on message" — `wrongVersion` uses the
        /// built-in default message, the others carry specific text.
        var expectedMessage: String? {
            switch self {
            case .missingMethod: "RPC data stream malformed"
            case .wrongVersion: nil
            case .readerFailure: "Error reading RPC request payload"
            }
        }
    }

    /// `RpcServerManager.handleIncomingRequestStream` error fan-out. For each
    /// malformed-input shape the server must publish a matching error packet
    /// on the v1 wire so the caller fails fast instead of hanging to its own
    /// response timeout. Matches JS.
    @Test(arguments: V2RequestErrorScenario.allCases)
    func v2RequestStreamErrorReturnsPacket(_ scenario: V2RequestErrorScenario) async throws {
        try await TestEnvironment.withRoom { room in
            await confirmation("Sends matching error packet (\(scenario.testDescription))") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          response.requestID == scenario.requestId,
                          case let .error(error) = response.value,
                          error.code == scenario.expectedCode
                    else { return }
                    if let expected = scenario.expectedMessage, error.message != expected { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                await room.rpcServer.handleIncomingRequestStream(
                    reader: scenario.makeReader(),
                    callerIdentity: Participant.Identity(from: "v2-caller")
                )
            }
        }
    }

    @Test(
        .spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L232"),
        .spec("https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md?plain=1#L240"),
        arguments: HandlerErrorScenario.allCases
    )
    func v2HandlerErrorReturnsPacket(_ scenario: HandlerErrorScenario) async throws {
        try await TestEnvironment.withRoom { room in
            try await confirmation("Sends v1 RpcResponse error packet (\(scenario.testDescription))") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    guard case let .rpcResponse(response) = packet.value,
                          case let .error(error) = response.value,
                          error.code == scenario.expectedCode
                    else { return }
                    if let expected = scenario.expectedMessage, error.message != expected { return }
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                try await room.registerRpcMethod("error-method") { _ in
                    switch scenario {
                    case .genericError: throw GenericTestError()
                    case .rpcErrorPassthrough: throw RpcError(code: 101, message: "Test error message", data: "")
                    }
                }

                let reader = RpcTestSupport.makeRequestReader(
                    requestId: "v2-req-error",
                    method: "error-method",
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
}

// swiftlint:enable type_body_length

// MARK: - Shared test support

private enum RpcTestSupport {
    /// Install a remote participant into `room` whose `clientProtocol` advertises the
    /// given version. Required for `performRpc` to read `remoteParticipants[...]?.clientProtocol`
    /// when there's no real signaling.
    static func installRemote(in room: Room, identity: Participant.Identity, clientProtocol: ClientProtocol) async throws {
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

    /// Builds a v2 request-stream reader. Pass `nil` for any attribute to omit
    /// it from the wire — used by negative tests that exercise the missing-attr
    /// error paths in `RpcServerManager.handleIncomingRequestStream`.
    static func makeRequestReader(
        requestId: String?,
        method: String?,
        payload: String,
        timeoutMs: UInt32?,
        version: String? = RPC_STREAM_VERSION
    ) -> TextStreamReader {
        var attributes: [String: String] = [:]
        if let requestId { attributes[RpcStreamAttribute.requestId] = requestId }
        if let method { attributes[RpcStreamAttribute.method] = method }
        if let timeoutMs { attributes[RpcStreamAttribute.timeoutMs] = String(timeoutMs) }
        if let version { attributes[RpcStreamAttribute.version] = version }
        let info = TextStreamInfo(
            id: UUID().uuidString,
            topic: RpcStreamTopic.request,
            timestamp: Date(),
            totalLength: nil,
            attributes: attributes,
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

    /// Builds a v2 response-stream reader. Pass `nil` for `requestId` to omit
    /// the correlation attribute — used by negative tests that exercise
    /// `RpcClientManager.handleIncomingResponseStream`'s missing-id branch.
    static func makeResponseReader(requestId: String?, payload: String) -> TextStreamReader {
        var attributes: [String: String] = [:]
        if let requestId { attributes[RpcStreamAttribute.requestId] = requestId }
        let info = TextStreamInfo(
            id: UUID().uuidString,
            topic: RpcStreamTopic.response,
            timestamp: Date(),
            totalLength: nil,
            attributes: attributes,
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

    /// Builds a v2 request-stream reader whose `readAll()` throws — simulates
    /// peer-closed or decrypt-failed mid-stream. Used to exercise the
    /// server-side `APPLICATION_ERROR` fast-fail branch.
    static func makeFailingRequestReader(
        requestId: String,
        method: String,
        timeoutMs: UInt32,
        error: Error = StreamError.terminated
    ) -> TextStreamReader {
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
            continuation.finish(throwing: error)
        }
        return TextStreamReader(info: info, source: source)
    }

    /// Builds a v2 response-stream reader whose `readAll()` throws — used to
    /// exercise the caller-side `APPLICATION_ERROR` fast-fail branch.
    static func makeFailingResponseReader(
        requestId: String,
        error: Error = StreamError.terminated
    ) -> TextStreamReader {
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
            continuation.finish(throwing: error)
        }
        return TextStreamReader(info: info, source: source)
    }
}

/// Async-safe append-only collector used to assert across concurrently-running tasks.
private actor TestStringCollector {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
