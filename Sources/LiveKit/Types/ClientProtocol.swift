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

/// Client-to-client protocol version advertised to other participants.
///
/// This is distinct from ``ProtocolVersion``, which tracks the *signaling* protocol
/// negotiated with the LiveKit server. ``ClientProtocol`` governs peer-to-peer feature
/// negotiation between participants.
@objc
public enum ClientProtocol: Int, Sendable {
    /// Legacy client. Only supports RPC v1 (inline `RpcRequest`/`RpcResponse` packets,
    /// hard-capped at 15 KB request/response payloads).
    case v0 = 0
    /// Adds RPC v2: request and response payloads transported over data streams,
    /// lifting the v1 15 KB payload size limit.
    case v1 = 1
}

// MARK: - Comparable

extension ClientProtocol: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - CustomStringConvertible

extension ClientProtocol: CustomStringConvertible {
    public var description: String {
        String(rawValue)
    }
}
