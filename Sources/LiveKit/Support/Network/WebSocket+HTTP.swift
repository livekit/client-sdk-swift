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

extension WebSocket {
    /// URLSession follows at most twenty HTTP redirects, drops Authorization even on the same host, and permits
    /// transitions between secure and cleartext WebSocket/HTTP URLs. The caller rebuilds Host and stored cookies.
    static func redirectedURL(_ response: WebSocketUpgradeFailure, from url: URL) throws -> URL? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode) else { return nil }
        let locations = response.headers.filter { $0.name == "location" }.map(\.value)
        guard locations.count == 1, let location = locations.first, !location.isEmpty,
              let target = URL(string: location, relativeTo: url)?.absoluteURL,
              var components = URLComponents(url: target, resolvingAgainstBaseURL: true) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws", "http": components.scheme = "ws"
        case "wss", "https": components.scheme = "wss"
        default: throw LiveKitError(.network, internalError: URLError(.unsupportedURL))
        }
        guard let host = components.host, !host.isEmpty else { throw LiveKitError(.network, internalError: URLError(.badURL)) }
        return components.url
    }
}
