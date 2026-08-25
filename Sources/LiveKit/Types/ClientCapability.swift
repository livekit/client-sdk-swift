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

/// An optional feature a client advertises support for at connect time.
///
/// Populated automatically by each SDK; not a user-configurable setting. Peers use
/// these flags to decide whether to enable features that require support on both
/// ends. This is distinct from ``ClientProtocol``, which is a single monotonic
/// version number rather than a set of independent feature flags.
///
/// Raw values match `livekit.ClientInfo.Capability` on the wire. The protocol's
/// `CAP_UNUSED` placeholder has no case here, and unrecognized values are dropped
/// rather than surfaced.
public enum ClientCapability: Int, Sendable, CaseIterable {
    /// The client can accept RTP packet trailers passed through by the SFU
    /// instead of having them stripped.
    case packetTrailer = 1
    /// The client can decode `deflate-raw` compressed payloads.
    case compressionDeflateRaw = 2
}
