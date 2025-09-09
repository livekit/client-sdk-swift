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

/// Specialized error handling for RPC methods.
///
/// Instances of this type, when thrown in a RPC method handler, will have their `message`
/// serialized and sent across the wire. The sender will receive an equivalent error on the other side.
///
/// Built-in types are included but developers may use any message string, with a max length of 256 bytes.
public struct RpcError: Error {
    /// The error code of the RPC call. Error codes 1001-1999 are reserved for built-in errors.
    ///
    /// See `RpcError.BuiltInError` for built-in error information.
    public let code: Int

    /// A message to include. Strings over 256 bytes will be truncated.
    public let message: String

    /// An optional data payload. Must be smaller than 15KB in size, or else will be truncated.
    public let data: String

    public enum BuiltInError {
        case applicationError
        case connectionTimeout
        case responseTimeout
        case recipientDisconnected
        case responsePayloadTooLarge
        case sendFailed
        case unsupportedMethod
        case recipientNotFound
        case requestPayloadTooLarge
        case unsupportedServer
        case unsupportedVersion

        public var code: Int {
            switch self {
            case .applicationError: 1500
            case .connectionTimeout: 1501
            case .responseTimeout: 1502
            case .recipientDisconnected: 1503
            case .responsePayloadTooLarge: 1504
            case .sendFailed: 1505
            case .unsupportedMethod: 1400
            case .recipientNotFound: 1401
            case .requestPayloadTooLarge: 1402
            case .unsupportedServer: 1403
            case .unsupportedVersion: 1404
            }
        }

        public var message: String {
            switch self {
            case .applicationError: "Application error in method handler"
            case .connectionTimeout: "Connection timeout"
            case .responseTimeout: "Response timeout"
            case .recipientDisconnected: "Recipient disconnected"
            case .responsePayloadTooLarge: "Response payload too large"
            case .sendFailed: "Failed to send"
            case .unsupportedMethod: "Method not supported at destination"
            case .recipientNotFound: "Recipient not found"
            case .requestPayloadTooLarge: "Request payload too large"
            case .unsupportedServer: "RPC not supported by server"
            case .unsupportedVersion: "Unsupported RPC version"
            }
        }

        func create(data: String = "") -> RpcError {
            RpcError(code: code, message: message, data: data)
        }
    }

    static func builtIn(_ key: BuiltInError, data: String = "") -> RpcError {
        RpcError(code: key.code, message: key.message, data: data)
    }

    static let MAX_MESSAGE_BYTES = 256
    static let MAX_DATA_BYTES = 15360 // 15 KB

    static func fromProto(_ proto: Livekit_RpcError) -> RpcError {
        RpcError(
            code: Int(proto.code),
            message: (proto.message).truncate(maxBytes: MAX_MESSAGE_BYTES),
            data: proto.data.truncate(maxBytes: MAX_DATA_BYTES)
        )
    }

    func toProto() -> Livekit_RpcError {
        Livekit_RpcError.with {
            $0.code = UInt32(code)
            $0.message = message
            $0.data = data
        }
    }
}

/*
 * Maximum payload size for RPC requests and responses. If a payload exceeds this size,
 * the RPC call will fail with a REQUEST_PAYLOAD_TOO_LARGE(1402) or RESPONSE_PAYLOAD_TOO_LARGE(1504) error.
 */
let MAX_RPC_PAYLOAD_BYTES = 15360 // 15 KB

/// A handler that processes an RPC request and returns a string
/// that will be sent back to the requester.
///
/// Throwing an `RpcError` will send the error back to the requester.
///
/// - SeeAlso: `LocalParticipant.registerRpcMethod`
public typealias RpcHandler = @Sendable (RpcInvocationData) async throws -> String

public struct RpcInvocationData {
    /// A unique identifier for this RPC request
    public let requestId: String

    /// The identity of the RemoteParticipant who initiated the RPC call
    public let callerIdentity: Participant.Identity

    /// The data sent by the caller (as a string)
    public let payload: String

    /// The maximum time available to return a response
    public let responseTimeout: TimeInterval
}

struct PendingRpcResponse: Sendable {
    let participantIdentity: Participant.Identity
    let onResolve: @Sendable (_ payload: String?, _ error: RpcError?) -> Void
}

actor RpcStateManager: Loggable {
    private var handlers: [String: RpcHandler] = [:] // methodName to handler
    private var pendingAcks: Set<String> = Set()
    private var pendingResponses: [String: PendingRpcResponse] = [:] // requestId to pending response

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

    func removeAllPending(_ requestId: String) async {
        pendingAcks.remove(requestId)
        pendingResponses.removeValue(forKey: requestId)
    }
}
