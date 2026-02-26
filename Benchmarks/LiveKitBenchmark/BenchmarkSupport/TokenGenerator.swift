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
import LiveKitUniFFI

/// Generates LiveKit access tokens for benchmark participants.
///
/// Uses LiveKitUniFFI's `tokenGenerate` function, which provides the same
/// HMAC-SHA256 JWT signing as the server SDKs.
struct TokenGenerator {
    let apiKey: String
    let apiSecret: String

    /// Generate a LiveKit access token.
    ///
    /// - Parameters:
    ///   - roomName: Room to grant access to
    ///   - identity: Participant identity
    ///   - canPublish: Whether the participant can publish tracks
    ///   - canSubscribe: Whether the participant can subscribe to tracks
    ///   - ttl: Token time-to-live in seconds (default: 300s / 5 minutes)
    func generate(
        roomName: String,
        identity: String,
        canPublish: Bool = true,
        canSubscribe: Bool = true,
        ttl: TimeInterval = 300
    ) -> String {
        let grants = VideoGrants(
            roomCreate: false,
            roomList: false,
            roomRecord: false,
            roomAdmin: false,
            roomJoin: true,
            room: roomName,
            destinationRoom: "",
            canPublish: canPublish,
            canSubscribe: canSubscribe,
            canPublishData: true,
            canPublishSources: [],
            canUpdateOwnMetadata: false,
            ingressAdmin: false,
            hidden: false,
            recorder: false
        )

        let options = TokenOptions(
            ttl: ttl,
            videoGrants: grants,
            identity: identity,
            name: identity
        )

        let credentials = ApiCredentials(
            key: apiKey,
            secret: apiSecret
        )

        do {
            return try tokenGenerate(options: options, credentials: credentials)
        } catch {
            fatalError("Failed to generate token: \(error)")
        }
    }
}
