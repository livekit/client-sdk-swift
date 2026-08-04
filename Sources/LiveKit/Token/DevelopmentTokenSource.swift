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

/// A token source that queries LiveKit's development token server for development and testing.
///
/// This token source connects to LiveKit Cloud's [development token server](https://docs.livekit.io/frontends/build/authentication/sandbox-token-server/),
/// which is perfect for quick prototyping and getting started with LiveKit development.
///
/// - Warning: This token source is **insecure** and should **never** be used in production.
/// - Note: For production use, implement ``EndpointTokenSource`` or your own ``TokenSourceConfigurable``.
public struct DevelopmentTokenSource: EndpointTokenSource {
    public let url = URL(string: "https://cloud-api.livekit.io/api/v2/sandbox/connection-details")!
    public var headers: [String: String] {
        ["X-Sandbox-ID": id]
    }

    /// The development token server ID provided by LiveKit Cloud for authentication.
    public let id: String

    /// Initialize with a development token server ID from LiveKit Cloud.
    ///
    /// - Parameter id: The token server ID obtained from your LiveKit Cloud project
    public init(id: String) {
        self.id = id.trimmingCharacters(in: .alphanumerics.inverted)
    }
}

/// A token source that queries LiveKit's sandbox token server for development and testing.
@available(*, deprecated, renamed: "DevelopmentTokenSource")
public typealias SandboxTokenSource = DevelopmentTokenSource
