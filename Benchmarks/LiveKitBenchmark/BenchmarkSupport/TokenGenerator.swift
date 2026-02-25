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

import CommonCrypto
import Foundation

/// Generates LiveKit access tokens (JWTs) for benchmark participants.
///
/// Uses HMAC-SHA256 signing with no external dependencies — the token format
/// is a standard JWT with LiveKit-specific claims.
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
        let now = Date()
        let exp = now.addingTimeInterval(ttl)

        // JWT Header
        let header: [String: Any] = [
            "alg": "HS256",
            "typ": "JWT",
        ]

        // JWT Payload with LiveKit claims
        let payload: [String: Any] = [
            "iss": apiKey,
            "sub": identity,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(exp.timeIntervalSince1970),
            "nbf": Int(now.timeIntervalSince1970),
            "jti": identity,
            "video": [
                "roomJoin": true,
                "room": roomName,
                "canPublish": canPublish,
                "canSubscribe": canSubscribe,
                "canPublishData": true,
            ] as [String: Any],
        ]

        let headerData = try! JSONSerialization.data(withJSONObject: header)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)

        let headerBase64 = base64URLEncode(headerData)
        let payloadBase64 = base64URLEncode(payloadData)

        let signingInput = "\(headerBase64).\(payloadBase64)"
        let signature = hmacSHA256(signingInput, secret: apiSecret)
        let signatureBase64 = base64URLEncode(signature)

        return "\(headerBase64).\(payloadBase64).\(signatureBase64)"
    }

    // MARK: - Private

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func hmacSHA256(_ string: String, secret: String) -> Data {
        let key = secret.data(using: .utf8)!
        let data = string.data(using: .utf8)!

        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyPtr.baseAddress, key.count,
                    dataPtr.baseAddress, data.count,
                    &hmac
                )
            }
        }

        return Data(hmac)
    }
}
