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

/// Cross-references to the RPC v2 specification (`livekit/client-sdk-js/RPC_SPEC.md`).
///
/// URL pinned to a specific upstream commit so line anchors stay stable
/// against future spec edits. Bump ``commit`` and re-verify the `line:`
/// arguments if any referenced case moves.
///
/// Pass these directly to `@Test(...)` — ``SpecCase`` is a typealias for
/// `URL`, and `URL` itself is a `TestTrait` (see `SpecCase.swift`):
/// ```swift
/// @Test(.tags(.spec), RpcSpec.V2V2.callerHappyShort)
/// func v2CallerHappyPathShort() async throws { … }
/// ```
enum RpcSpec {
    /// Upstream commit the line anchors below were captured against.
    static let commit = "92c72f06"

    /// Base URL of the pinned spec doc (markdown source view).
    static let baseURL = URL(string:
        "https://github.com/livekit/client-sdk-js/blob/\(commit)/RPC_SPEC.md")!

    /// Construct a deep-link URL pointing at a specific line in the spec doc.
    /// `?plain=1` requests GitHub's source-view renderer so the `#L<n>`
    /// anchor actually scrolls/highlights the target line.
    private static func line(_ line: Int) -> SpecCase {
        URL(string: "\(baseURL.absoluteString)?plain=1#L\(line)")!
    }

    // MARK: - v2 → v2 (both sides support data streams)

    /// Required test cases when both caller and handler advertise
    /// `clientProtocol >= CLIENT_PROTOCOL_DATA_STREAM_RPC`.
    enum V2V2 {
        /// Case #1: Caller happy path (short payload).
        static let callerHappyShort: SpecCase = RpcSpec.line(204)
        /// Case #2: Caller happy path (large payload > 15 KB).
        static let callerHappyLarge: SpecCase = RpcSpec.line(213)
        /// Case #3: Handler happy path.
        static let handlerHappy: SpecCase = RpcSpec.line(222)
        /// Case #4: Unhandled error in handler → APPLICATION_ERROR packet.
        static let unhandledError: SpecCase = RpcSpec.line(232)
        /// Case #5: RpcError passthrough from handler.
        static let rpcErrorPassthrough: SpecCase = RpcSpec.line(240)
        /// Case #6: Response timeout.
        static let responseTimeout: SpecCase = RpcSpec.line(247)
        /// Case #7: Error response.
        static let errorResponse: SpecCase = RpcSpec.line(252)
        /// Case #8: Participant disconnection.
        static let participantDisconnect: SpecCase = RpcSpec.line(258)
    }

    // MARK: - v2 → v1 (v2 caller, v1 handler)

    /// Required test cases when a v2-capable caller falls back to v1 because
    /// the remote's `clientProtocol` is `CLIENT_PROTOCOL_DEFAULT` (`0`).
    enum V2V1 {
        /// Case #10: Caller happy path (request fallback).
        static let callerHappy: SpecCase = RpcSpec.line(265)
        /// Case #11: Handler happy path (v1 request).
        static let handlerHappy: SpecCase = RpcSpec.line(274)
        /// Case #12: Payload too large.
        static let payloadTooLarge: SpecCase = RpcSpec.line(283)
        /// Case #13: Response timeout.
        static let responseTimeout: SpecCase = RpcSpec.line(289)
        /// Case #14: Error response.
        static let errorResponse: SpecCase = RpcSpec.line(295)
        /// Case #15: Participant disconnection.
        static let participantDisconnect: SpecCase = RpcSpec.line(302)
    }

    // MARK: - v1 → v2 (v1 caller, v2 handler)

    /// Required test cases when a legacy v1 caller (`clientProtocol = 0`)
    /// addresses a v2-capable handler.
    enum V1V2 {
        /// Case #16: Handler happy path (response fallback).
        static let handlerResponseFallback: SpecCase = RpcSpec.line(310)
        /// Case #17: Unhandled error in handler (v1 caller).
        static let unhandledError: SpecCase = RpcSpec.line(318)
        /// Case #18: RpcError passthrough (v1 caller).
        static let rpcErrorPassthrough: SpecCase = RpcSpec.line(324)
    }
}
