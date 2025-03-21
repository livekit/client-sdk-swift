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

@objc
public enum ReconnectMode: Int, Sendable {
    /// Quick reconnection mode attempts to maintain the same session, reusing existing
    /// transport connections and published tracks. This is faster but may not succeed
    /// in all network conditions.
    case quick

    /// Full reconnection mode performs a complete new connection to the LiveKit server,
    /// closing existing connections and re-publishing all tracks. This is slower but
    /// more reliable for recovering from severe connection issues.
    case full
}

@objc
public enum ConnectionState: Int, Sendable {
    case disconnected
    case connecting
    case reconnecting
    case connected
}

extension ConnectionState: Identifiable {
    public var id: Int {
        rawValue
    }
}
