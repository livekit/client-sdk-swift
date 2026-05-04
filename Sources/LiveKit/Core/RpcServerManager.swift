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

/// Handler-side RPC.
///
/// Owns the registered method-handler table and the wire-level handling of incoming
/// RPC requests (both v1 packets and v2 streams). `Room.registerRpcMethod` and
/// `Room.unregisterRpcMethod` are one-line proxies that forward into this actor.
actor RpcServerManager: Loggable {
    private weak var room: Room?

    private var handlers: [String: RpcHandler] = [:] // methodName to handler

    func attach(to room: Room) {
        self.room = room
    }

    // MARK: - Public handler registration

    func registerHandler(_ method: String, handler: @escaping RpcHandler) throws {
        guard !isRpcMethodRegistered(method) else {
            throw LiveKitError(.invalidState, message: "RPC method '\(method)' already registered")
        }
        handlers[method] = handler
    }

    func unregisterHandler(_ method: String) {
        if handlers.removeValue(forKey: method) == nil {
            log("No handler registered for RPC method '\(method)'", .warning)
        }
    }

    func isRpcMethodRegistered(_ method: String) -> Bool {
        handlers[method] != nil
    }

    func getHandler(for method: String) -> RpcHandler? {
        handlers[method]
    }

    // MARK: - Incoming dispatch

    /// Handle an RPC request that arrived as a v1 `RpcRequest` packet. Always responds via
    /// a v1 `RpcResponse` packet, since the caller signaled v1 transport by using a packet.
    func handleIncomingRequest(callerIdentity: Participant.Identity,
                               requestId: String,
                               method: String,
                               payload: String,
                               responseTimeout: TimeInterval,
                               version: Int) async
    {
        guard let room = try? requireRoom() else { return }

        do {
            try await publishAck(in: room, destinationIdentity: callerIdentity, requestId: requestId)
        } catch {
            log("[Rpc] Failed to publish RPC ack for \(requestId)", .error)
        }

        guard version == 1 else {
            do {
                try await publishResponse(in: room,
                                          destinationIdentity: callerIdentity,
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
                                             responseTimeout: responseTimeout)
        do {
            switch result {
            case let .success(payload):
                try await publishResponse(in: room,
                                          destinationIdentity: callerIdentity,
                                          requestId: requestId,
                                          payload: payload,
                                          error: nil)
            case let .failure(error):
                try await publishResponse(in: room,
                                          destinationIdentity: callerIdentity,
                                          requestId: requestId,
                                          payload: nil,
                                          error: error)
            }
        } catch {
            log("[Rpc] Failed to publish RPC response for \(requestId)", .error)
        }
    }

    /// Handle an RPC request that arrived as a v2 data stream on the `lk.rpc_request` topic.
    /// Successful responses are sent back as a data stream on `lk.rpc_response`; errors are
    /// sent as v1 `RpcResponse` packets per the spec.
    func handleIncomingRequestStream(reader: TextStreamReader,
                                     callerIdentity: Participant.Identity) async
    {
        guard let room = try? requireRoom() else { return }

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
            try await publishAck(in: room, destinationIdentity: callerIdentity, requestId: requestId)
        } catch {
            log("[Rpc] Failed to publish RPC ack for \(requestId)", .error)
        }

        guard version == RPC_STREAM_VERSION else {
            do {
                try await publishResponse(in: room,
                                          destinationIdentity: callerIdentity,
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
                                             responseTimeout: responseTimeout)
        do {
            switch result {
            case let .success(responsePayload):
                try await publishResponseStream(in: room,
                                                destinationIdentity: callerIdentity,
                                                requestId: requestId,
                                                payload: responsePayload)
            case let .failure(error):
                // Per spec: error responses always use v1 packet, even when both sides are v2.
                try await publishResponse(in: room,
                                          destinationIdentity: callerIdentity,
                                          requestId: requestId,
                                          payload: nil,
                                          error: error)
            }
        } catch {
            log("[Rpc] Failed to publish RPC response for \(requestId)", .error)
        }
    }

    // MARK: - Handler dispatch

    private enum DispatchResult {
        case success(String)
        case failure(RpcError)
    }

    /// Look up the handler for `method`, invoke it, and produce a payload-or-error result.
    /// The 15 KB response cap only applies on v1 (packet) response transports.
    private func dispatchToHandler(callerIdentity: Participant.Identity,
                                   requestId: String,
                                   method: String,
                                   payload: String,
                                   responseTimeout: TimeInterval) async -> DispatchResult
    {
        guard let handler = handlers[method] else {
            return .failure(RpcError.builtIn(.unsupportedMethod))
        }

        do {
            let response = try await handler(RpcInvocationData(requestId: requestId,
                                                               callerIdentity: callerIdentity,
                                                               payload: payload,
                                                               responseTimeout: responseTimeout
                                                               ))
            if response.byteLength > MAX_RPC_PAYLOAD_BYTES {
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

    // MARK: - Outgoing wire

    private func publishResponse(in room: Room,
                                 destinationIdentity: Participant.Identity,
                                 requestId: String,
                                 payload: String?,
                                 error: RpcError?) async throws
    {
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

    private func publishResponseStream(in room: Room,
                                       destinationIdentity: Participant.Identity,
                                       requestId: String,
                                       payload: String) async throws
    {
        let options = StreamTextOptions(
            topic: RpcStreamTopic.response,
            attributes: [RpcStreamAttribute.requestId: requestId],
            destinationIdentities: [destinationIdentity]
        )
        let writer = try await room.localParticipant.streamText(options: options)
        try await writer.write(payload)
        try await writer.close()
    }

    private func publishAck(in room: Room,
                            destinationIdentity: Participant.Identity,
                            requestId: String) async throws
    {
        let dataPacket = Livekit_DataPacket.with {
            $0.destinationIdentities = [destinationIdentity.stringValue]
            $0.kind = .reliable
            $0.rpcAck = Livekit_RpcAck.with {
                $0.requestID = requestId
            }
        }

        try await room.send(dataPacket: dataPacket)
    }

    // MARK: - Helpers

    private func requireRoom() throws -> Room {
        guard let room else { throw RpcError.builtIn(.applicationError) }
        return room
    }
}
