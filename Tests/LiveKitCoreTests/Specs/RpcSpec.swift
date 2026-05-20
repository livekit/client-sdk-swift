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

/// Cross-references to the RPC v2 specification
/// (`livekit/client-sdk-js/RPC_SPEC.md`), pinned to a specific upstream
/// commit so line anchors stay stable against future spec edits.
///
/// Each case is a `URL` deep-linked into the spec doc. Pass directly to
/// `.spec(...)`:
///
/// ```swift
/// @Test(.spec(Rpc.V2V2.callerHappyPathShort))
/// func v2CallerHappyPathShort() async throws { … }
/// ```
///
/// Bump ``commit`` and re-verify each `line(...)` argument if any
/// referenced case moves in the upstream spec.
enum Rpc {
    /// Upstream commit the line anchors below were captured against.
    static let commit = "92c72f06"

    /// Base URL of the pinned spec doc (markdown source view).
    static let baseURL = URL(string:
        "https://github.com/livekit/client-sdk-js/blob/\(commit)/RPC_SPEC.md")!

    /// Construct a deep-link URL pointing at a specific line in the spec doc.
    /// `?plain=1` requests GitHub's source-view renderer so the `#L<n>`
    /// anchor actually scrolls/highlights the target line.
    private static func line(_ line: Int) -> URL {
        URL(string: "\(baseURL.absoluteString)?plain=1#L\(line)")!
    }

    // MARK: - v2 → v2 (both sides support data streams)

    /// Required cases when both caller and handler advertise
    /// `clientProtocol >= CLIENT_PROTOCOL_DATA_STREAM_RPC`.
    enum V2V2 {
        /// Case #1: Caller happy path (short payload).
        static let callerHappyPathShort = Rpc.line(204)
        /// Case #2: Caller happy path (large payload > 15 KB).
        static let callerHappyPathLarge = Rpc.line(213)
        /// Case #3: Handler happy path.
        static let handlerHappyPath = Rpc.line(222)
        /// Case #4: Unhandled error in handler → APPLICATION_ERROR packet.
        static let unhandledError = Rpc.line(232)
        /// Case #5: RpcError passthrough from handler.
        static let rpcErrorPassthrough = Rpc.line(240)
        /// Case #6: Response timeout.
        static let responseTimeout = Rpc.line(247)
        /// Case #7: Error response.
        static let errorResponse = Rpc.line(252)
        /// Case #8: Participant disconnection.
        static let participantDisconnect = Rpc.line(258)
    }

    // MARK: - v2 → v1 (v2 caller, v1 handler)

    /// Required cases when a v2-capable caller falls back to v1 because
    /// the remote's `clientProtocol` is `CLIENT_PROTOCOL_DEFAULT` (`0`).
    enum V2V1 {
        /// Case #10: Caller happy path (request fallback).
        static let callerHappyPath = Rpc.line(265)
        /// Case #11: Handler happy path (v1 request).
        static let handlerHappyPath = Rpc.line(274)
        /// Case #12: Payload too large.
        static let payloadTooLarge = Rpc.line(283)
        /// Case #13: Response timeout.
        static let responseTimeout = Rpc.line(289)
        /// Case #14: Error response.
        static let errorResponse = Rpc.line(295)
        /// Case #15: Participant disconnection.
        static let participantDisconnect = Rpc.line(302)
    }

    // MARK: - v1 → v2 (v1 caller, v2 handler)

    /// Required cases when a legacy v1 caller (`clientProtocol = 0`)
    /// addresses a v2-capable handler.
    enum V1V2 {
        /// Case #16: Handler happy path (response fallback).
        static let handlerResponseFallback = Rpc.line(310)
        /// Case #17: Unhandled error in handler (v1 caller).
        static let unhandledError = Rpc.line(318)
        /// Case #18: RpcError passthrough (v1 caller).
        static let rpcErrorPassthrough = Rpc.line(324)
    }
}
