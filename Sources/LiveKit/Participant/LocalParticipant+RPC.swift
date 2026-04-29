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

// MARK: - Public RPC methods

public extension LocalParticipant {
    /// Initiate an RPC call to a remote participant.
    ///
    /// Transport selection is automatic and invisible to the caller:
    /// - If the remote participant supports RPC v2 (`clientProtocol >= 1`), the request and
    ///   any successful response are carried over data streams (no payload size limit).
    /// - Otherwise the request is sent as a v1 `RpcRequest` packet, which is subject to a
    ///   15 KB payload size limit (otherwise rejected with `REQUEST_PAYLOAD_TOO_LARGE`).
    ///
    /// ObjC: auto-generated as
    /// `performRpcWithDestinationIdentity:method:payload:responseTimeout:completionHandler:`.
    ///
    /// - Parameters:
    ///   - destinationIdentity: The identity of the destination participant
    ///   - method: The method name to call
    ///   - payload: The payload to pass to the method
    ///   - responseTimeout: Timeout for receiving a response after the initial connection (in seconds).
    ///     If a value less than 8s is provided, it will be automatically clamped to 8s
    ///     to ensure sufficient time for round-trip latency buffering.
    ///     Default: 15s.
    /// - Returns: The response payload
    /// - Throws: RpcError on failure. Details in RpcError.message
    func performRpc(destinationIdentity: Identity,
                    method: String,
                    payload: String,
                    responseTimeout: TimeInterval = 15) async throws -> String
    {
        let room = try requireRoom()

        let remoteClientProtocol = room.remoteParticipants[destinationIdentity]?.clientProtocol ?? .v0
        let useStreamTransport = remoteClientProtocol >= .v1

        if !useStreamTransport, payload.byteLength > MAX_RPC_PAYLOAD_BYTES {
            throw RpcError.builtIn(.requestPayloadTooLarge)
        }

        let requestId = UUID().uuidString
        let maxRoundTripLatency: TimeInterval = 7
        let minEffectiveTimeout: TimeInterval = 1
        let effectiveTimeout = max(responseTimeout - maxRoundTripLatency, minEffectiveTimeout)

        if useStreamTransport {
            try await publishRpcRequestStream(destinationIdentity: destinationIdentity,
                                              requestId: requestId,
                                              method: method,
                                              payload: payload,
                                              responseTimeout: effectiveTimeout)
        } else {
            try await publishRpcRequest(destinationIdentity: destinationIdentity,
                                        requestId: requestId,
                                        method: method,
                                        payload: payload,
                                        responseTimeout: effectiveTimeout)
        }

        do {
            return try await withThrowingTimeout(timeout: responseTimeout) {
                try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await room.rpcClient.addPendingAck(requestId)

                        await room.rpcClient.setPendingResponse(requestId, response: PendingRpcResponse(
                            participantIdentity: destinationIdentity,
                            onResolve: { payload, error in
                                Task {
                                    await room.rpcClient.removePendingAck(requestId)
                                    await room.rpcClient.removePendingResponse(requestId)

                                    if let error {
                                        continuation.resume(throwing: error)
                                    } else {
                                        continuation.resume(returning: payload ?? "")
                                    }
                                }
                            }
                        ))
                    }

                    Task {
                        try await Task.sleep(nanoseconds: UInt64(maxRoundTripLatency * 1_000_000_000))

                        if await room.rpcClient.hasPendingAck(requestId) {
                            await room.rpcClient.removeAllPending(requestId)
                            continuation.resume(throwing: RpcError.builtIn(.connectionTimeout))
                        }
                    }
                }
            }
        } catch {
            if let error = error as? LiveKitError {
                if error.type == .timedOut {
                    throw RpcError.builtIn(.connectionTimeout)
                }
            }
            throw error
        }
    }

    @available(*, deprecated, message: "registerRpcMethod(_:handler:) has been moved to room.")
    func registerRpcMethod(_ method: String,
                           handler: @escaping RpcHandler) async
    {
        guard let room = try? requireRoom() else { return }
        do {
            try await room.registerRpcMethod(method, handler: handler)
        } catch {
            guard let error = error as? LiveKitError,
                  let message = error.message else { return }
            log("\(message)", .error)
        }
    }

    @available(*, deprecated, message: "unregisterRpcMethod(_:) has been moved to room.")
    func unregisterRpcMethod(_ method: String) async {
        guard let room = try? requireRoom() else { return }
        await room.unregisterRpcMethod(method)
    }
}

// MARK: - RPC Internal — outgoing transport

extension LocalParticipant {
    private func publishRpcRequest(destinationIdentity: Identity,
                                   requestId: String,
                                   method: String,
                                   payload: String,
                                   responseTimeout: TimeInterval = 10) async throws
    {
        guard payload.byteLength <= MAX_RPC_PAYLOAD_BYTES else {
            throw LiveKitError(.invalidParameter,
                               message: "cannot publish data larger than \(MAX_RPC_PAYLOAD_BYTES)")
        }

        let room = try requireRoom()

        let dataPacket = Livekit_DataPacket.with {
            $0.destinationIdentities = [destinationIdentity.stringValue]
            $0.kind = .reliable
            $0.rpcRequest = Livekit_RpcRequest.with {
                $0.id = requestId
                $0.method = method
                $0.payload = payload
                $0.responseTimeoutMs = UInt32(responseTimeout * 1000)
                $0.version = 1
            }
        }

        try await room.send(dataPacket: dataPacket)
    }

    private func publishRpcRequestStream(destinationIdentity: Identity,
                                         requestId: String,
                                         method: String,
                                         payload: String,
                                         responseTimeout: TimeInterval) async throws
    {
        let options = StreamTextOptions(
            topic: RpcStreamTopic.request,
            attributes: [
                RpcStreamAttribute.requestId: requestId,
                RpcStreamAttribute.method: method,
                RpcStreamAttribute.timeoutMs: String(UInt32(responseTimeout * 1000)),
                RpcStreamAttribute.version: RPC_STREAM_VERSION,
            ],
            destinationIdentities: [destinationIdentity]
        )
        let writer = try await streamText(options: options)
        try await writer.write(payload)
        try await writer.close()
    }

    private func publishRpcResponse(destinationIdentity: Identity,
                                    requestId: String,
                                    payload: String?,
                                    error: RpcError?) async throws
    {
        let room = try requireRoom()

        let dataPacket = Livekit_DataPacket.with {
            $0.destinationIdentities = [destinationIdentity.stringValue]
            $0.kind = .reliable
            $0.rpcResponse = Livekit_RpcResponse.with {
                $0.requestID = requestId
                if let error {
                    $0.error = error.toProto()
                } else {
                    $0.payload = payload ?? ""
                }
            }
        }

        try await room.send(dataPacket: dataPacket)
    }

    private func publishRpcResponseStream(destinationIdentity: Identity,
                                          requestId: String,
                                          payload: String) async throws
    {
        let options = StreamTextOptions(
            topic: RpcStreamTopic.response,
            attributes: [RpcStreamAttribute.requestId: requestId],
            destinationIdentities: [destinationIdentity]
        )
        let writer = try await streamText(options: options)
        try await writer.write(payload)
        try await writer.close()
    }

    private func publishRpcAck(destinationIdentity: Identity,
                               requestId: String) async throws
    {
        let room = try requireRoom()

        let dataPacket = Livekit_DataPacket.with {
            $0.destinationIdentities = [destinationIdentity.stringValue]
            $0.kind = .reliable
            $0.rpcAck = Livekit_RpcAck.with {
                $0.requestID = requestId
            }
        }

        try await room.send(dataPacket: dataPacket)
    }
}

// MARK: - RPC Internal — incoming dispatch

extension LocalParticipant {
    /// Dispatch result: payload (success) or RpcError (failure).
    private enum DispatchResult {
        case success(String)
        case failure(RpcError)
    }

    /// Look up the handler for `method`, invoke it, and produce a payload-or-error result.
    /// The 15 KB response cap only applies on v1 (packet) response transports.
    private func dispatchToHandler(callerIdentity: Identity,
                                   requestId: String,
                                   method: String,
                                   payload: String,
                                   responseTimeout: TimeInterval,
                                   enforcePayloadCap: Bool) async -> DispatchResult
    {
        guard let room = try? requireRoom() else {
            return .failure(RpcError.builtIn(.applicationError))
        }
        guard let handler = await room.rpcServer.getHandler(for: method) else {
            return .failure(RpcError.builtIn(.unsupportedMethod))
        }

        do {
            let response = try await handler(RpcInvocationData(requestId: requestId,
                                                               callerIdentity: callerIdentity,
                                                               payload: payload,
                                                               responseTimeout: responseTimeout))
            if enforcePayloadCap, response.byteLength > MAX_RPC_PAYLOAD_BYTES {
                log("[Rpc] Response payload too large for \(method)", .warning)
                return .failure(RpcError.builtIn(.responsePayloadTooLarge))
            }
            return .success(response)
        } catch let error as RpcError {
            return .failure(error)
        } catch {
            log("[Rpc] Uncaught error returned by RPC handler for \(method). Returning APPLICATION_ERROR instead.", .warning)
            return .failure(RpcError.builtIn(.applicationError))
        }
    }

    /// Handles an RPC request that arrived as a v1 `RpcRequest` packet. Always responds via
    /// a v1 `RpcResponse` packet, since the caller signaled v1 transport by using a packet.
    func handleIncomingRpcRequest(callerIdentity: Identity,
                                  requestId: String,
                                  method: String,
                                  payload: String,
                                  responseTimeout: TimeInterval,
                                  version: Int) async
    {
        do {
            try await publishRpcAck(destinationIdentity: callerIdentity, requestId: requestId)
        } catch {
            log("[Rpc] Failed to publish RPC ack for \(requestId)", .error)
        }

        guard version == 1 else {
            do {
                try await publishRpcResponse(destinationIdentity: callerIdentity,
                                             requestId: requestId,
                                             payload: nil,
                                             error: RpcError.builtIn(.unsupportedVersion))
            } catch {
                log("[Rpc] Failed to publish RPC error response for \(requestId)", .error)
            }
            return
        }

        let result = await dispatchToHandler(callerIdentity: callerIdentity,
                                             requestId: requestId,
                                             method: method,
                                             payload: payload,
                                             responseTimeout: responseTimeout,
                                             enforcePayloadCap: true)
        do {
            switch result {
            case let .success(payload):
                try await publishRpcResponse(destinationIdentity: callerIdentity,
                                             requestId: requestId,
                                             payload: payload,
                                             error: nil)
            case let .failure(error):
                try await publishRpcResponse(destinationIdentity: callerIdentity,
                                             requestId: requestId,
                                             payload: nil,
                                             error: error)
            }
        } catch {
            log("[Rpc] Failed to publish RPC response for \(requestId)", .error)
        }
    }

    /// Handles an RPC request that arrived as a v2 data stream on the `lk.rpc_request` topic.
    /// Successful responses are sent back as a data stream on `lk.rpc_response`; errors are
    /// sent as v1 `RpcResponse` packets per the spec.
    func handleIncomingRpcRequestStream(reader: TextStreamReader,
                                        callerIdentity: Identity) async
    {
        let attrs = reader.info.attributes
        guard let requestId = attrs[RpcStreamAttribute.requestId],
              let method = attrs[RpcStreamAttribute.method],
              let timeoutMsString = attrs[RpcStreamAttribute.timeoutMs],
              let timeoutMs = UInt32(timeoutMsString)
        else {
            log("[Rpc] Incoming v2 RPC request stream is missing required attributes", .error)
            return
        }
        let version = attrs[RpcStreamAttribute.version] ?? ""
        let responseTimeout = TimeInterval(timeoutMs) / 1000

        do {
            try await publishRpcAck(destinationIdentity: callerIdentity, requestId: requestId)
        } catch {
            log("[Rpc] Failed to publish RPC ack for \(requestId)", .error)
        }

        guard version == RPC_STREAM_VERSION else {
            do {
                try await publishRpcResponse(destinationIdentity: callerIdentity,
                                             requestId: requestId,
                                             payload: nil,
                                             error: RpcError.builtIn(.unsupportedVersion))
            } catch {
                log("[Rpc] Failed to publish RPC error response for \(requestId)", .error)
            }
            return
        }

        let payload: String
        do {
            payload = try await reader.readAll()
        } catch {
            log("[Rpc] Failed to read v2 RPC request payload for \(requestId): \(error)", .error)
            return
        }

        let result = await dispatchToHandler(callerIdentity: callerIdentity,
                                             requestId: requestId,
                                             method: method,
                                             payload: payload,
                                             responseTimeout: responseTimeout,
                                             enforcePayloadCap: false)
        do {
            switch result {
            case let .success(responsePayload):
                try await publishRpcResponseStream(destinationIdentity: callerIdentity,
                                                   requestId: requestId,
                                                   payload: responsePayload)
            case let .failure(error):
                // Per spec: error responses always use v1 packet, even when both sides are v2.
                try await publishRpcResponse(destinationIdentity: callerIdentity,
                                             requestId: requestId,
                                             payload: nil,
                                             error: error)
            }
        } catch {
            log("[Rpc] Failed to publish RPC response for \(requestId)", .error)
        }
    }

    func handleIncomingRpcAck(requestId: String) {
        Task {
            guard let room = try? requireRoom() else { return }
            await room.rpcClient.removePendingAck(requestId)
        }
    }

    func handleIncomingRpcResponse(requestId: String,
                                   payload: String?,
                                   error: RpcError?)
    {
        Task {
            guard let room = try? requireRoom() else { return }
            guard let handler = await room.rpcClient.removePendingResponse(requestId) else {
                log("[Rpc] Response received for unexpected RPC request, id = \(requestId)", .error)
                return
            }

            handler.onResolve(payload, error)
        }
    }

    /// Handle a v2 response stream on the `lk.rpc_response` topic. Reads the
    /// `lk.rpc_request_id` attribute to match against pending requests, then resolves
    /// with the streamed payload.
    func handleIncomingRpcResponseStream(reader: TextStreamReader,
                                         senderIdentity _: Identity) async
    {
        guard let requestId = reader.info.attributes[RpcStreamAttribute.requestId] else {
            log("[Rpc] Incoming v2 RPC response stream is missing request id attribute", .error)
            return
        }
        let payload: String
        do {
            payload = try await reader.readAll()
        } catch {
            log("[Rpc] Failed to read v2 RPC response payload for \(requestId): \(error)", .error)
            return
        }

        guard let room = try? requireRoom() else { return }
        guard let pending = await room.rpcClient.removePendingResponse(requestId) else {
            log("[Rpc] Response stream received for unexpected RPC request, id = \(requestId)", .error)
            return
        }
        pending.onResolve(payload, nil)
    }
}
