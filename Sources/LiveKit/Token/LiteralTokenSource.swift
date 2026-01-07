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

/// A token source that provides a fixed set of credentials without dynamic fetching.
///
/// This is useful for testing, development, or when you have pre-generated tokens
/// that don't need to be refreshed dynamically.
///
/// - Note: For dynamic token fetching, use ``EndpointTokenSource`` or implement ``TokenSourceConfigurable``.
public struct LiteralTokenSource: TokenSourceFixed {
    /// The LiveKit server URL to connect to.
    let serverURL: URL
    /// The JWT token for participant authentication.
    let participantToken: String
    /// The display name for the participant (optional).
    let participantName: String?
    /// The name of the room to join (optional).
    let roomName: String?

    /// Initialize with fixed credentials.
    ///
    /// - Parameters:
    ///   - serverURL: The LiveKit server URL to connect to
    ///   - participantToken: The JWT token for participant authentication
    ///   - participantName: The display name for the participant (optional)
    ///   - roomName: The name of the room to join (optional)
    public init(serverURL: URL, participantToken: String, participantName: String? = nil, roomName: String? = nil) {
        self.serverURL = serverURL
        self.participantToken = participantToken
        self.participantName = participantName
        self.roomName = roomName
    }

    /// Returns the fixed credentials without any network requests.
    ///
    /// - Returns: A `TokenSourceResponse` containing the pre-configured credentials
    public func fetch() async throws -> TokenSourceResponse {
        TokenSourceResponse(serverURL: serverURL, participantToken: participantToken, participantName: participantName, roomName: roomName)
    }
}
