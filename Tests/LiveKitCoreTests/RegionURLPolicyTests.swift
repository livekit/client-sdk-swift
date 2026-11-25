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
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// The URL-level policy the region trust check enforces.
///
/// Separate from ``RegionManagerTests``, which covers the manager's fetch and cache
/// behaviour: these are pure predicate cases, and keeping them here stops either suite
/// outgrowing SwiftLint's `type_body_length` limit as cases are added.
@Suite(.tags(.networking)) struct RegionURLPolicyTests {
    @Test(arguments: [
        ("wss://test.livekit.cloud", true),
        ("wss://test.livekit.run", true),
        ("wss://self-hosted.example.com", false),
        ("ws://localhost:7880", false),
    ])
    func isCloud(urlString: String, expected: Bool) throws {
        let url = try #require(URL(string: urlString))
        #expect(url.isCloud == expected)
    }

    @Test(arguments: [
        ("wss://test.livekit.cloud", "https://test.livekit.cloud/settings/regions"),
        ("ws://test.livekit.cloud", "http://test.livekit.cloud/settings/regions"),
        ("https://test.livekit.cloud", "https://test.livekit.cloud/settings/regions"),
    ])
    func regionSettingsUrlConversion(input: String, expected: String) {
        #expect(URL(string: input)?.regionSettingsUrl().absoluteString == expected)
    }

    @Test(arguments: [
        // Encrypted cloud URLs are the only thing failover may use.
        ("wss://eu.livekit.cloud", true),
        ("https://eu.livekit.cloud", true),
        ("wss://staging.livekit.run", true),
        ("https://eu.livekit.cloud:443/rtc", true),
        // Foundation does not normalise host case, so this must still match.
        ("https://EU.LIVEKIT.CLOUD", true),
        // Cleartext must never carry the token, even to a real cloud host.
        ("ws://eu.livekit.cloud", false),
        ("http://eu.livekit.cloud", false),
        // Foreign origins, and near-misses that must not match on suffix alone.
        ("https://other.example.com", false),
        ("wss://other.example.com/rtc", false),
        ("https://not-livekit.cloud", false),
        ("https://livekit.cloud.example.com", false),
        // Malformed or hostless.
        ("", false),
        ("eu.livekit.cloud", false),
        ("file:///etc/passwd", false),

        // --- Policy pins for host-parsing edge cases ---------------------------------------
        // The case that actually matters: a cloud name in the *userinfo* does not make the
        // destination a cloud host. Foundation resolves this to `evil.com`.
        ("wss://eu.livekit.cloud@evil.com", false),
        // Credentials on an otherwise valid cloud URL. Refused: discovery never returns these.
        ("wss://user:pass@eu.livekit.cloud", false),
        ("wss://user@eu.livekit.cloud", false),
        // Fully-qualified trailing dot resolves to the same host but does not match the
        // suffix. Refused, which is the safe direction.
        ("wss://eu.livekit.cloud.", false),
        // IP literals are never a cloud host.
        ("wss://1.2.3.4", false),
        ("wss://[::1]", false),
        // Percent-encoding is decoded before the match, so an encoded dot is still the real
        // host and is accepted; an encoded slash is not, and lands outside the suffix.
        ("wss://eu.livekit%2Ecloud", true),
        ("wss://eu.livekit.cloud%2F.evil.com", false),
    ])
    func isTrustedRegionURL(urlString: String, expected: Bool) {
        #expect(URL(string: urlString)?.isTrustedRegionURL ?? false == expected)
    }
}
