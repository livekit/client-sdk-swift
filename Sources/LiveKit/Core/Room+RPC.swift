/*
 * Copyright 2025 LiveKit
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

public extension Room {
    /// Establishes the participant as a receiver for calls of the specified RPC method.
    /// Will overwrite any existing callback for the same method.
    ///
    /// Example:
    /// ```swift
    /// try await room.localParticipant.registerRpcMethod("greet") { data in
    ///     print("Received greeting from \(data.callerIdentity): \(data.payload)")
    ///     return "Hello, \(data.callerIdentity)!"
    /// }
    /// ```
    ///
    /// The handler receives an `RpcInvocationData` containing the following parameters:
    /// - `requestId`: A unique identifier for this RPC request
    /// - `callerIdentity`: The identity of the RemoteParticipant who initiated the RPC call
    /// - `payload`: The data sent by the caller (as a string)
    /// - `responseTimeout`: The maximum time available to return a response
    ///
    /// The handler should return a string.
    /// If unable to respond within responseTimeout, the request will result in an error on the caller's side.
    ///
    /// You may throw errors of type RpcError with a string message in the handler,
    /// and they will be received on the caller's side with the message intact.
    /// Other errors thrown in your handler will not be transmitted as-is, and will instead arrive to the caller as 1500 ("Application Error").
    ///
    /// - Parameters:
    ///   - method: The name of the indicated RPC method
    ///   - handler: Will be invoked when an RPC request for this method is received
    ///
    func registerRpcMethod(_ method: String,
                           handler: @escaping RpcHandler) async throws
    {
        try await rpcState.registerHandler(method, handler: handler)
    }

    /// Unregisters a previously registered RPC method.
    ///
    /// - Parameter method: The name of the RPC method to unregister
    ///
    func unregisterRpcMethod(_ method: String) async {
        await rpcState.unregisterHandler(method)
    }

    /// Checks whether or not a handler has been registered for an RPC method.
    ///
    /// - Parameter method: The name of the RPC method to check.
    /// - Returns: `true` if a handler has been registered, otherwise `false`.
    ///
    func isRpcMethodRegistered(_ method: String) async -> Bool {
        await rpcState.isRpcMethodRegistered(method)
    }
}
