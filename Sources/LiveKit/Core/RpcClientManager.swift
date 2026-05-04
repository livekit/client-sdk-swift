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

    /// Test-only hook fired once after the RPC request has been published but before the
    /// caller starts waiting on the completer. Receives the freshly-generated `requestId`
    /// so a test can simulate a fast remote ack/response that races the wait. No-op outside
    /// of tests.
    var __test_afterPublishHook: (@Sendable (String) async -> Void)?

    func attach(to room: Room) {
        self.room = room
    }

    func __test_setAfterPublishHook(_ hook: (@Sendable (String) async -> Void)?) {
        __test_afterPublishHook = hook
    }

    /// Test-only: synchronously fires the ack-timeout watchdog's terminal action for
    /// `requestId`, exactly as the 7-second timer would. Used to deterministically exercise
    /// the watchdog/response double-resolve race without waiting on the real timer.
    func __test_forceAckTimeout(requestId: String) {
        fireAckTimeoutIfPending(requestId: requestId)
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

        // Pre-register pending state synchronously on the actor *before* publishing the
        // request. Prevents a race where a fast remote can ack/respond before registration
        // completes — the response would otherwise log "received for unexpected request" and
        // the call would hang to the outer responseTimeout.
        let completer = AsyncCompleter<String>(label: "rpc-\(requestId)", defaultTimeout: responseTimeout)
        pendingAcks.insert(requestId)
        pendingResponses[requestId] = PendingRpcResponse(
            participantIdentity: destinationIdentity,
            completer: completer
        )

        do {
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
        } catch {
            // Publish failed — clean up the registered state before re-throwing.
            removeAllPending(requestId)
            throw error
        }

        if let hook = __test_afterPublishHook {
            await hook(requestId)
        }

        // Ack watchdog: fail fast if no ack arrives within maxRoundTripLatency. Note that
        // `completer.resume` is idempotent (AsyncCompleter), so a real response that lands
        // mid-flight here cannot crash via double-resolve — the second resume is a silent
        // no-op and the first resolution wins.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(maxRoundTripLatency * 1_000_000_000))
            guard let self else { return }
            await self.fireAckTimeoutIfPending(requestId: requestId)
        }

        defer {
            pendingAcks.remove(requestId)
            pendingResponses.removeValue(forKey: requestId)
        }
        do {
            return try await completer.wait()
        } catch {
            if let error = error as? LiveKitError, error.type == .timedOut {
                throw RpcError.builtIn(.connectionTimeout)
            }
            throw error
        }
    }

    /// Watchdog terminal action: if `requestId` is still awaiting an ack, clear pending
    /// state and resolve its completer with `connectionTimeout`. AsyncCompleter idempotency
    /// makes this safe even if a real response has already resolved the completer between
    /// the watchdog scheduling and this call running.
    private func fireAckTimeoutIfPending(requestId: String) {
        guard pendingAcks.contains(requestId) else { return }
        pendingAcks.remove(requestId)
        let pending = pendingResponses.removeValue(forKey: requestId)
        pending?.completer.resume(throwing: RpcError.builtIn(.connectionTimeout))
    }

    // MARK: - Incoming dispatch

    /// Resolve a pending RPC call from a v1 `RpcResponse` packet. Note that `pendingAcks`
    /// is intentionally not cleared here — the watchdog's gate stays armed until either
    /// `handleIncomingAck` or `fireAckTimeoutIfPending` clears it. Either path is safe
    /// because the completer is idempotent.
    func handleIncomingResponse(requestId: String,
                                payload: String?,
                                error: RpcError?)
    {
        guard let pending = pendingResponses.removeValue(forKey: requestId) else {
            log("[Rpc] Response received for unexpected RPC request, id = \(requestId)", .error)
            return
        }
        if let error {
            pending.completer.resume(throwing: error)
        } else {
            pending.completer.resume(returning: payload ?? "")
        }
    }

    /// Resolve a pending RPC call from a v2 response stream on `lk.rpc_response`. Reads the
    /// `lk.rpc_request_id` attribute to match against pending requests, then resolves
    /// with the streamed payload — but only if `senderIdentity` matches the original
    /// destination of the call. A response from any other peer is ignored (and the
    /// pending entry is left in place so the legitimate sender can still resolve).
    func handleIncomingResponseStream(reader: TextStreamReader, senderIdentity: Participant.Identity) async {
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

        guard let pending = pendingResponses[requestId] else {
            log("[Rpc] Response stream received for unexpected RPC request, id = \(requestId)", .error)
            return
        }
        guard pending.participantIdentity == senderIdentity else {
            log("[Rpc] Response stream for \(requestId) from wrong sender (expected \(pending.participantIdentity), got \(senderIdentity)); ignoring", .error)
            return
        }
        pendingResponses.removeValue(forKey: requestId)
        pending.completer.resume(returning: payload)
    }

    /// Clear the pending-ack flag for a request when an `RpcAck` arrives.
    func handleIncomingAck(requestId: String) {
        pendingAcks.remove(requestId)
    }

    /// Reject every in-flight RPC targeting `identity` with `recipientDisconnected`
    /// (1503). Called from `Room._onParticipantDidDisconnect(identity:)` so the caller
    /// learns immediately instead of waiting for the user-supplied `responseTimeout`.
    /// AsyncCompleter idempotency makes this safe even if a real response races the
    /// disconnect.
    func handleParticipantDisconnected(_ identity: Participant.Identity) {
        let toReap = pendingResponses.filter { $0.value.participantIdentity == identity }
        for (requestId, pending) in toReap {
            pendingResponses.removeValue(forKey: requestId)
            pendingAcks.remove(requestId)
            pending.completer.resume(throwing: RpcError.builtIn(.recipientDisconnected))
        }
    }

    /// Reject every in-flight RPC with `recipientDisconnected`. Called from
    /// `Room.cleanUp(...)` during teardown / full reconnect — at that point no
    /// participant survives, so identity-filtering is unnecessary.
    func handleAllPendingDisconnected() {
        for (_, pending) in pendingResponses {
            pending.completer.resume(throwing: RpcError.builtIn(.recipientDisconnected))
        }
        pendingResponses.removeAll()
        pendingAcks.removeAll()
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

    /// Number of in-flight RPCs awaiting a response. Exposed for test-time leak checks.
    var pendingCount: Int {
        pendingResponses.count
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
