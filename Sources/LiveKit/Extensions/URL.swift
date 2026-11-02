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

    var isValidForSocket: Bool {
        host != nil && (scheme == "ws" || scheme == "wss")
    }

    var isSecure: Bool {
        scheme == "https" || scheme == "wss"
    }

    /// Checks whether the URL is a LiveKit Cloud URL.
    var isCloud: Bool {
        guard let host else { return false }
        return host.hasSuffix(".livekit.cloud") || host.hasSuffix(".livekit.run")
    }

    func cloudConfigUrl() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.scheme = scheme?.replacingOccurrences(of: "ws", with: "http")
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = "/settings"
        return components.url!
    }

    func regionSettingsUrl() -> URL {
        cloudConfigUrl().appendingPathComponent("regions")
    }

    /// Returns the canonical base URL used to key per-URL RegionManager instances.
    func regionManagerKeyURL() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil

        var pathSegments = components?.path.split(separator: "/").map(String.init) ?? []
        if let last = pathSegments.last, ["rtc", "validate"].contains(last) {
            pathSegments.removeLast()
        }

        let basePath = pathSegments.isEmpty ? "/" : "/" + pathSegments.joined(separator: "/") + "/"
        components?.path = basePath

        return components?.url ?? self
    }

    func matchesRegionManagerKey(of other: URL) -> Bool {
        regionManagerKeyURL() == other.regionManagerKeyURL()
    }

    func toSocketUrl() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.scheme = scheme?.replacingOccurrences(of: "http", with: "ws")
        return components.url!
    }

    func toHTTPUrl() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.scheme = scheme?.replacingOccurrences(of: "ws", with: "http")
        return components.url!
    }
}
