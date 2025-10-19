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
@testable import LiveKit

public class TokenGenerator {
    // 30 mins
    public static let defaultTTL: TimeInterval = 30 * 60

    // MARK: - Public

    public var apiKey: String
    public var apiSecret: String
    public var identity: String
    public var ttl: TimeInterval
    public var name: String?
    public var metadata: String?
    public var videoGrant: LiveKitJWTPayload.VideoGrant?

    // MARK: - Private

    private let signers = JWTSigners()

    public init(apiKey: String,
                apiSecret: String,
                identity: String,
                ttl: TimeInterval = defaultTTL)
    {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.identity = identity
        self.ttl = ttl
    }

    public func sign() throws -> String {
        // Add HMAC with SHA-256 signer.
        signers.use(.hs256(key: apiSecret))

        let n = Date().timeIntervalSince1970

        let p = LiveKitJWTPayload(exp: .init(value: Date(timeIntervalSince1970: floor(n + ttl))),
                                  iss: .init(stringLiteral: apiKey),
                                  nbf: .init(value: Date(timeIntervalSince1970: floor(n))),
                                  sub: .init(stringLiteral: identity),
                                  name: name,
                                  metadata: metadata,
                                  video: videoGrant)

        return try signers.sign(p)
    }
}
