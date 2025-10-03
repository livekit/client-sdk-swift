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

public protocol TokenSourceFixed: Sendable {
    func fetch() async throws -> TokenSourceResponse
}

public protocol TokenSourceConfigurable: Sendable {
    func fetch(_ options: TokenRequestOptions) async throws -> TokenSourceResponse
}

// MARK: - Token

/// Request parameters for generating connection credentials.
public struct TokenRequestOptions: Encodable, Sendable, Equatable {
    /// The name of the room being requested when generating credentials.
    public let roomName: String?
    /// The name of the participant being requested for this client when generating credentials.
    public let participantName: String?
    /// The identity of the participant being requested for this client when generating credentials.
    public let participantIdentity: String?
    /// Any participant metadata being included along with the credentials generation operation.
    public let participantMetadata: String?
    /// Any participant attributes being included along with the credentials generation operation.
    public let participantAttributes: [String: String]?
    /// A `RoomConfiguration` object can be passed to request extra parameters when generating connection credentials.
    /// Used for advanced room configuration like dispatching agents, setting room limits, etc.
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

/// Response containing the credentials needed to connect to a room.
public struct TokenSourceResponse: Decodable, Sendable {
    /// The WebSocket URL for the LiveKit server.
    public let serverURL: URL
    /// The JWT token containing participant permissions and metadata.
    public let participantToken: String
    /// The name of the participant being requested for this client when generating credentials.
    public let participantName: String?
    /// The name of the room being requested when generating credentials.
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
