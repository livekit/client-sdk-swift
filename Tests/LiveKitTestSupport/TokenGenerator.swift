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
@testable import LiveKit
import LiveKitUniFFI

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

    public var videoGrants: LiveKitUniFFI.VideoGrants?
    public var roomConfiguration: LiveKitUniFFI.RoomConfiguration?

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
        let credentials = ApiCredentials(key: apiKey, secret: apiSecret)
        let options = TokenOptions(
            ttl: ttl,
            videoGrants: videoGrants,
            sipGrants: nil,
            identity: identity,
            name: name,
            metadata: metadata,
            attributes: nil,
            sha256: nil,
            roomConfiguration: roomConfiguration
        )

        return try tokenGenerate(options: options, credentials: credentials)
    }
}
