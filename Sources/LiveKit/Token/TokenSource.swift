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

// MARK: - Source

/// A token source that returns a fixed set of credentials without configurable options.
///
/// This protocol is designed for backwards compatibility with existing authentication infrastructure
/// that doesn't support dynamic room, participant, or agent parameter configuration.
///
/// - Note: Use ``LiteralTokenSource`` to provide a fixed set of credentials synchronously.
public protocol TokenSourceFixed: Sendable {
    func fetch() async throws -> TokenSourceResponse
}

/// A token source that provides configurable options for room, participant, and agent parameters.
///
/// This protocol allows dynamic configuration of connection parameters, making it suitable for
/// production applications that need flexible authentication and room management.
///
/// Common implementations:
/// - ``SandboxTokenSource``: For testing with LiveKit Cloud sandbox [token server](https://cloud.livekit.io/projects/p_/sandbox/templates/token-server)
/// - ``EndpointTokenSource``: For custom backend endpoints using LiveKit's JSON format
/// - ``CachingTokenSource``: For caching credentials (or use the `.cached()` extension)
public protocol TokenSourceConfigurable: Sendable {
    func fetch(_ options: TokenRequestOptions) async throws -> TokenSourceResponse
}

// MARK: - Token

/// Request parameters for generating connection credentials.
public struct TokenRequestOptions: Encodable, Sendable, Equatable {
    /// The name of the room to connect to. Required for most token generation scenarios.
    public let roomName: String?
    /// The display name for the participant in the room. Optional but recommended for user experience.
    public let participantName: String?
    /// A unique identifier for the participant. Used for permissions and room management.
    public let participantIdentity: String?
    /// Custom metadata associated with the participant. Can be used for user profiles or additional context.
    public let participantMetadata: String?
    /// Custom attributes for the participant. Useful for storing key-value data like user roles or preferences.
    public let participantAttributes: [String: String]?
    /// Advanced room configuration options for token generation.
    ///
    /// Use this for advanced features like:
    /// - Dispatching agents to the room
    /// - Setting room limits and constraints
    /// - Configuring recording or streaming options
    ///
    /// - SeeAlso: [Room Configuration Documentation](https://docs.livekit.io/home/get-started/authentication/#room-configuration) for more info.
    public let roomConfiguration: RoomConfiguration?

    enum CodingKeys: String, CodingKey {
        case roomName = "room_name"
        case participantName = "participant_name"
        case participantIdentity = "participant_identity"
        case participantMetadata = "participant_metadata"
        case participantAttributes = "participant_attributes"
        case roomConfiguration = "room_config"
    }

    public init(
        roomName: String? = nil,
        participantName: String? = nil,
        participantIdentity: String? = nil,
        participantMetadata: String? = nil,
        participantAttributes: [String: String]? = nil,
        roomConfiguration: RoomConfiguration? = nil
    ) {
        self.roomName = roomName
        self.participantName = participantName
        self.participantIdentity = participantIdentity
        self.participantMetadata = participantMetadata
        self.participantAttributes = participantAttributes
        self.roomConfiguration = roomConfiguration
    }
}

/// Response containing the credentials needed to connect to a LiveKit room.
public struct TokenSourceResponse: Decodable, Sendable {
    /// The WebSocket URL for the LiveKit server. Use this to establish the connection.
    public let serverURL: URL
    /// The JWT token containing participant permissions and metadata. Required for authentication.
    public let participantToken: String
    /// The display name for the participant in the room. May be nil if not specified.
    public let participantName: String?
    /// The name of the room the participant will join. May be nil if not specified.
    public let roomName: String?

    enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case participantToken = "participant_token"
        case participantName = "participant_name"
        case roomName = "room_name"
    }

    public init(serverURL: URL, participantToken: String, participantName: String? = nil, roomName: String? = nil) {
        self.serverURL = serverURL
        self.participantToken = participantToken
        self.participantName = participantName
        self.roomName = roomName
    }
}
