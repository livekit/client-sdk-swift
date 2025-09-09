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
import JWTKit

public struct VideoGrant: Codable, Equatable {
    /** name of the room, must be set for admin or join permissions */
    let room: String?
    /** permission to create a room */
    let roomCreate: Bool?
    /** permission to join a room as a participant, room must be set */
    let roomJoin: Bool?
    /** permission to list rooms */
    let roomList: Bool?
    /** permission to start a recording */
    let roomRecord: Bool?
    /** permission to control a specific room, room must be set */
    let roomAdmin: Bool?

    /**
     * allow participant to publish. If neither canPublish or canSubscribe is set,
     * both publish and subscribe are enabled
     */
    let canPublish: Bool?
    /** allow participant to subscribe to other tracks */
    let canSubscribe: Bool?
    /**
     * allow participants to publish data, defaults to true if not set
     */
    let canPublishData: Bool?
    /** allowed sources for publishing */
    let canPublishSources: [String]? // String as returned in the JWT
    /** participant isn't visible to others */
    let hidden: Bool?
    /** participant is recording the room, when set, allows room to indicate it's being recorded */
    let recorder: Bool?

    init(room: String? = nil,
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

public class TokenGenerator {
    private struct Payload: JWTPayload, Equatable {
        let exp: ExpirationClaim
        let iss: IssuerClaim
        let nbf: NotBeforeClaim
        let sub: SubjectClaim

        let name: String?
        let metadata: String?
        let video: VideoGrant?

        func verify(using _: JWTSigner) throws {
            fatalError("not implemented")
        }
    }

    // 30 mins
    static let defaultTTL: TimeInterval = 30 * 60

    // MARK: - Public

    public var apiKey: String
    public var apiSecret: String
    public var identity: String
    public var ttl: TimeInterval
    public var name: String?
    public var metadata: String?
    public var videoGrant: VideoGrant?

    // MARK: - Private

    private let signers = JWTSigners()

    init(apiKey: String,
         apiSecret: String,
         identity: String,
         ttl: TimeInterval = defaultTTL)
    {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.identity = identity
        self.ttl = ttl
    }

    func sign() throws -> String {
        // Add HMAC with SHA-256 signer.
        signers.use(.hs256(key: apiSecret))

        let n = Date().timeIntervalSince1970

        let p = Payload(exp: .init(value: Date(timeIntervalSince1970: floor(n + ttl))),
                        iss: .init(stringLiteral: apiKey),
                        nbf: .init(value: Date(timeIntervalSince1970: floor(n))),
                        sub: .init(stringLiteral: identity),
                        name: name,
                        metadata: metadata,
                        video: videoGrant)

        return try signers.sign(p)
    }
}
