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
        try await requireRoom().rpcClient.performRpc(destinationIdentity: destinationIdentity,
                                                     method: method,
                                                     payload: payload,
                                                     responseTimeout: responseTimeout)
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
