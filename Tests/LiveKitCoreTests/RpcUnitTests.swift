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

@Suite(.tags(.rpc))
struct RpcUnitTests {
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
    @Test func performRpcRejectsOnRecipientDisconnect() async throws {
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

    // MARK: - v1 server-side handler dispatch

    @Test func handleIncomingRpcRequest() async throws {
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

    @Test func rpcErrorHandling() async throws {
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

    // MARK: - v2 wire-format & state-machine internals

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

    /// Caller times out waiting for the response. With `responseTimeout < maxRoundTripLatency`,
    /// the completer's `defaultTimeout` fires before the ack-watchdog and surfaces as
    /// `responseTimeout` (1502) — `connectionTimeout` (1501) is reserved for the
    /// ack-watchdog path.
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
                #expect(error.code == RpcError.BuiltInError.responseTimeout.code)
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
                // Ack arrived (legitimately) but the spoofed response was ignored, so the
                // completer's user-supplied `responseTimeout` (1s) elapses → 1502.
                #expect(error.code == RpcError.BuiltInError.responseTimeout.code)
            }
            #expect(await room.rpcClient.pendingCount == 0)
        }
    }
}

// swiftlint:enable type_body_length

// MARK: - Test support

enum RpcTestSupport {
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
actor TestStringCollector {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
