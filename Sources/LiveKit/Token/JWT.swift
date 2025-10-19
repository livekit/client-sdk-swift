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

import JWTKit

/// JWT payload structure for LiveKit authentication tokens.
public struct LiveKitJWTPayload: JWTPayload, Codable, Equatable {
    /// Video-specific permissions and room access grants for the participant.
    public struct VideoGrant: Codable, Equatable {
        /// Name of the room. Required for admin or join permissions.
        public let room: String?
        /// Permission to create new rooms.
        public let roomCreate: Bool?
        /// Permission to join a room as a participant. Requires `room` to be set.
        public let roomJoin: Bool?
        /// Permission to list available rooms.
        public let roomList: Bool?
        /// Permission to start recording sessions.
        public let roomRecord: Bool?
        /// Permission to control a specific room. Requires `room` to be set.
        public let roomAdmin: Bool?

        /// Allow participant to publish tracks. If neither `canPublish` or `canSubscribe` is set, both are enabled.
        public let canPublish: Bool?
        /// Allow participant to subscribe to other participants' tracks.
        public let canSubscribe: Bool?
        /// Allow participant to publish data messages. Defaults to `true` if not set.
        public let canPublishData: Bool?
        /// Allowed track sources for publishing (e.g., "camera", "microphone", "screen_share").
        public let canPublishSources: [String]?
        /// Hide participant from other participants in the room.
        public let hidden: Bool?
        /// Mark participant as a recorder. When set, allows room to indicate it's being recorded.
        public let recorder: Bool?

        public init(room: String? = nil,
                    roomCreate: Bool? = nil,
                    roomJoin: Bool? = nil,
                    roomList: Bool? = nil,
                    roomRecord: Bool? = nil,
                    roomAdmin: Bool? = nil,
                    canPublish: Bool? = nil,
                    canSubscribe: Bool? = nil,
                    canPublishData: Bool? = nil,
                    canPublishSources: [String]? = nil,
                    hidden: Bool? = nil,
                    recorder: Bool? = nil)
        {
            self.room = room
            self.roomCreate = roomCreate
            self.roomJoin = roomJoin
            self.roomList = roomList
            self.roomRecord = roomRecord
            self.roomAdmin = roomAdmin
            self.canPublish = canPublish
            self.canSubscribe = canSubscribe
            self.canPublishData = canPublishData
            self.canPublishSources = canPublishSources
            self.hidden = hidden
            self.recorder = recorder
        }
    }

    /// JWT expiration time claim (when the token expires).
    public let exp: ExpirationClaim
    /// JWT issuer claim (who issued the token).
    public let iss: IssuerClaim
    /// JWT not-before claim (when the token becomes valid).
    public let nbf: NotBeforeClaim
    /// JWT subject claim (the participant identity).
    public let sub: SubjectClaim

    /// Display name for the participant in the room.
    public let name: String?
    /// Custom metadata associated with the participant.
    public let metadata: String?
    /// Video-specific permissions and room access grants.
    public let video: VideoGrant?

    /// Verifies the JWT token's validity by checking expiration and not-before claims.
    public func verify(using _: JWTSigner) throws {
        try nbf.verifyNotBefore()
        try exp.verifyNotExpired()
    }

    /// Creates a JWT payload from an unverified token string.
    ///
    /// - Parameter token: The JWT token string to parse
    /// - Returns: The parsed JWT payload if successful, nil otherwise
    static func fromUnverified(token: String) -> Self? {
        try? JWTSigners().unverified(token, as: Self.self)
    }
}
