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

/// Caller-side RPC.
///
/// Owns the in-flight bookkeeping (pending acks and pending responses) and the wire-level
/// publishing of v1 RPC packets / v2 RPC request streams. `LocalParticipant.performRpc`
/// is a one-line proxy that forwards into this actor.
actor RpcClientManager: Loggable {
    private weak var room: Room?

    private var pendingAcks: Set<String> = Set()
    private var pendingResponses: [String: PendingRpcResponse] = [:] // requestId to pending response

    func attach(to room: Room) {
        self.room = room
    }

    // MARK: - Public entry point

    /// Initiate an RPC call to a remote participant. Transport selection is automatic and
    /// matches the SDK's documented behavior: peer's `clientProtocol >= .v1` → v2 data stream,
    /// otherwise v1 packet.
    func performRpc(destinationIdentity: Participant.Identity,
                    method: String,
                    payload: String,
                    responseTimeout: TimeInterval = 15) async throws -> String
    {
        let room = try requireRoom()

        let remoteClientProtocol = room.remoteParticipants[destinationIdentity]?.clientProtocol ?? .v0
        print("Rpc - Remote client protocol: \(remoteClientProtocol)")
        let useStreamTransport = remoteClientProtocol >= .v1

        if !useStreamTransport, payload.byteLength > MAX_RPC_PAYLOAD_BYTES {
            throw RpcError.builtIn(.requestPayloadTooLarge)
        }

        let requestId = UUID().uuidString
        let maxRoundTripLatency: TimeInterval = 7
        let minEffectiveTimeout: TimeInterval = 1
        let effectiveTimeout = max(responseTimeout - maxRoundTripLatency, minEffectiveTimeout)

        if useStreamTransport {
            try await publishRequestStream(in: room,
                                           destinationIdentity: destinationIdentity,
                                           requestId: requestId,
                                           method: method,
                                           payload: payload,
                                           responseTimeout: effectiveTimeout)
        } else {
            try await publishRequest(in: room,
                                     destinationIdentity: destinationIdentity,
                                     requestId: requestId,
                                     method: method,
                                     payload: payload,
                                     responseTimeout: effectiveTimeout)
        }

        do {
            return try await withThrowingTimeout(timeout: responseTimeout) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    Task { [weak self] in
                        guard let self else {
                            continuation.resume(throwing: RpcError.builtIn(.applicationError))
                            return
                        }
                        await self.addPendingAck(requestId)
                        await self.setPendingResponse(requestId, response: PendingRpcResponse(
                            participantIdentity: destinationIdentity,
                            onResolve: { [weak self] payload, error in
                                Task {
                                    await self?.removePendingAck(requestId)
                                    await self?.removePendingResponse(requestId)
                                    if let error {
                                        continuation.resume(throwing: error)
                                    } else {
                                        continuation.resume(returning: payload ?? "")
                                    }
                                }
                            }
                        ))
                    }

                    Task { [weak self] in
                        try await Task.sleep(nanoseconds: UInt64(maxRoundTripLatency * 1_000_000_000))
                        guard let self else { return }
                        if await self.hasPendingAck(requestId) {
                            await self.removeAllPending(requestId)
                            continuation.resume(throwing: RpcError.builtIn(.connectionTimeout))
                        }
                    }
                }
            }
        } catch {
            if let error = error as? LiveKitError, error.type == .timedOut {
                throw RpcError.builtIn(.connectionTimeout)
            }
            throw error
        }
    }

    // MARK: - Incoming dispatch

    /// Resolve a pending RPC call from a v1 `RpcResponse` packet.
    func handleIncomingResponse(requestId: String,
                                payload: String?,
                                error: RpcError?)
    {
        guard let pending = pendingResponses.removeValue(forKey: requestId) else {
            log("[Rpc] Response received for unexpected RPC request, id = \(requestId)", .error)
            return
        }
        pending.onResolve(payload, error)
    }

    /// Resolve a pending RPC call from a v2 response stream on `lk.rpc_response`. Reads the
    /// `lk.rpc_request_id` attribute to match against pending requests, then resolves
    /// with the streamed payload.
    func handleIncomingResponseStream(reader: TextStreamReader, senderIdentity _: Participant.Identity) async {
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

        guard let pending = pendingResponses.removeValue(forKey: requestId) else {
            log("[Rpc] Response stream received for unexpected RPC request, id = \(requestId)", .error)
            return
        }
        pending.onResolve(payload, nil)
    }

    /// Clear the pending-ack flag for a request when an `RpcAck` arrives.
    func handleIncomingAck(requestId: String) {
        pendingAcks.remove(requestId)
    }

    // MARK: - State ops

    func addPendingAck(_ requestId: String) {
        pendingAcks.insert(requestId)
    }

    @discardableResult
    func removePendingAck(_ requestId: String) -> Bool {
        pendingAcks.remove(requestId) != nil
    }

    func hasPendingAck(_ requestId: String) -> Bool {
        pendingAcks.contains(requestId)
    }

    func setPendingResponse(_ requestId: String, response: PendingRpcResponse) {
        pendingResponses[requestId] = response
    }

    @discardableResult
    func removePendingResponse(_ requestId: String) -> PendingRpcResponse? {
        pendingResponses.removeValue(forKey: requestId)
    }

    func removeAllPending(_ requestId: String) {
        pendingAcks.remove(requestId)
        pendingResponses.removeValue(forKey: requestId)
    }

    // MARK: - Outgoing wire

    private func publishRequest(in room: Room,
                                destinationIdentity: Participant.Identity,
                                requestId: String,
                                method: String,
                                payload: String,
                                responseTimeout: TimeInterval) async throws
    {
        guard payload.byteLength <= MAX_RPC_PAYLOAD_BYTES else {
            throw LiveKitError(.invalidParameter,
                               message: "cannot publish data larger than \(MAX_RPC_PAYLOAD_BYTES)")
        }

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

    private func publishRequestStream(in room: Room,
                                      destinationIdentity: Participant.Identity,
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
        let writer = try await room.localParticipant.streamText(options: options)
        try await writer.write(payload)
        try await writer.close()
    }

    // MARK: - Helpers

    private func requireRoom() throws -> Room {
        guard let room else { throw RpcError.builtIn(.applicationError) }
        return room
    }
}
