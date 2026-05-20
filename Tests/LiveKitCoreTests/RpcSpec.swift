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

/// External specifications cross-referenced by tests in this target via
/// the agnostic ``SpecCase`` trait.
enum RpcSpec {
    /// RPC v2 specification — the canonical document listing required test
    /// cases for any conforming SDK-to-SDK RPC implementation.
    ///
    /// URL is **pinned to a specific commit** in `livekit/client-sdk-js` so the
    /// section anchors and case numbering used by `.spec(...)` traits remain
    /// stable against future edits or filesystem moves. Bump the SHA when the
    /// upstream spec changes in a way that affects the cases referenced here.
    static let url = URL(string:
        "https://github.com/livekit/client-sdk-js/blob/92c72f06/RPC_SPEC.md")!
}
