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

extension URL {
    var isValidForConnect: Bool {
        host != nil && (scheme == "ws" || scheme == "wss" || scheme == "https" || scheme == "http")
    }

    /// Checks whether the URL is a LiveKit Cloud URL.
    var isCloud: Bool {
        guard let host else { return false }
        return host.hasSuffix(".livekit.cloud") || host.hasSuffix(".livekit.run")
    }

    func toHTTPUrl() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.scheme = scheme?.replacingOccurrences(of: "ws", with: "http")
        return components.url!
    }
}
