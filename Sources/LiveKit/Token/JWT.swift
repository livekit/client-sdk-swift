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

public struct LiveKitJWTPayload: JWTPayload, Codable, Equatable {
    public struct VideoGrant: Codable, Equatable {
        /// Name of the room, must be set for admin or join permissions
        public let room: String?
        /// Permission to create a room
        public let roomCreate: Bool?
        /// Permission to join a room as a participant, room must be set
        public let roomJoin: Bool?
        /// Permission to list rooms
        public let roomList: Bool?
        /// Permission to start a recording
        public let roomRecord: Bool?
        /// Permission to control a specific room, room must be set
        public let roomAdmin: Bool?

        /// Allow participant to publish. If neither canPublish or canSubscribe is set, both publish and subscribe are enabled
        public let canPublish: Bool?
        /// Allow participant to subscribe to other tracks
        public let canSubscribe: Bool?
        /// Allow participants to publish data, defaults to true if not set
        public let canPublishData: Bool?
        /// Allowed sources for publishing
        public let canPublishSources: [String]?
        /// Participant isn't visible to others
        public let hidden: Bool?
        /// Participant is recording the room, when set, allows room to indicate it's being recorded
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

    /// Expiration time claim
    public let exp: ExpirationClaim
    /// Issuer claim
    public let iss: IssuerClaim
    /// Not before claim
    public let nbf: NotBeforeClaim
    /// Subject claim
    public let sub: SubjectClaim

    /// Participant name
    public let name: String?
    /// Participant metadata
    public let metadata: String?
    /// Video grants for the participant
    public let video: VideoGrant?

    public func verify(using _: JWTSigner) throws {
        try nbf.verifyNotBefore()
        try exp.verifyNotExpired()
    }

    static func fromUnverified(token: String) -> Self? {
        try? JWTSigners().unverified(token, as: Self.self)
    }
}
