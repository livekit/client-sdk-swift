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

/// `Sandbox` queries LiveKit Sandbox token server for credentials,
/// which supports quick prototyping/getting started types of use cases.
/// - Warning: This token endpoint is **INSECURE** and should **NOT** be used in production.
public struct Sandbox: TokenEndpoint {
    public let url = URL(string: "https://cloud-api.livekit.io/api/sandbox/connection-details")!
    public var headers: [String: String] {
        ["X-Sandbox-ID": id]
    }

    /// The sandbox ID provided by LiveKit Cloud.
    public let id: String

    /// Initialize with a sandbox ID from LiveKit Cloud.
    public init(id: String) {
        self.id = id.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
