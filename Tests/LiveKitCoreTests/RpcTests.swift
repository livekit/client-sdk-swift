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

                guard request.method == "test-method", request.payload == "test-payload", request.responseTimeoutMs == 15000 else {
                    return
                }

                // Trigger fake response packets. Pre-registration in performRpc is
                // synchronous on the actor before publish, so the ack/response can fire
                // immediately without a sleep.
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

            // Use the post-publish hook to deterministically know when performRpc has
            // pre-registered pending state, instead of polling/sleeping.
            let registered = AsyncCompleter<Void>(label: "performRpc-registered", defaultTimeout: 5)
            await room.rpcClient.__test_setAfterPublishHook { _ in
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

    // MARK: - v2 e2e tests (real WebRTC, two rooms via withRooms)

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

    // MARK: - v2 unit tests (wire-format & state-machine internals)

    //
    // These tests assert behaviors that are invisible at the participant boundary
    // (wire-format choices, ack-timeout state machine, sender-identity validation)
    // and so retain their existing 1-room + `MockDataChannelPair` setup.

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
    @Test(arguments: HandlerErrorScenario.allCases)
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

    /// Caller times out if no ack arrives.
    @Test func v2CallerResponseTimeout() async throws {
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
                #expect(error.code == RpcError.BuiltInError.connectionTimeout.code)
            } catch {
                Issue.record("Unexpected error type: \(error)")
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
                // Should time out / connection-timeout since no legitimate response arrived.
                #expect(error.code == RpcError.BuiltInError.connectionTimeout.code)
            }
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }
}

// swiftlint:enable type_body_length

// MARK: - Test support

private enum RpcTestSupport {
    /// Insert a remote participant into `room` whose `clientProtocol` advertises v2.
    static func installRemote(in room: Room, identity: Participant.Identity, clientProtocol: ClientProtocol) async throws {
        try install(in: room, identity: identity, clientProtocol: clientProtocol)
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
