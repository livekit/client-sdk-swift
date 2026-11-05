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

extension WebSocketLifecycleTests {
    /// A protection space is the root URL and the realm (RFC 7235 §2.2): a second realm on the same origin gets its own
    /// credential, as URLSession answered it.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func secondBasicRealmOnTheSameOriginIsAnswered() async throws {
        let realms = ["lk-auth-\(UUID().uuidString)-a", "lk-auth-\(UUID().uuidString)-b"]
        let server = try FakeWebSocketServer(.upgradeResponses(realms.map(Self.basicChallenge) + [Self.successfulHTTPUpgrade]))
        defer { server.cancel() }
        let url = try await server.url()
        let stored = try realms.map { try Self.storeBasicCredential(url: url, realm: $0, user: $0) }
        defer { for (space, credential) in stored {
            URLCredentialStorage.shared.remove(credential, for: space)
        } }

        let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
        defer { socket.close() }
        let requests = server.requests.copy()
        #expect(requests.map { Self.authorization($0.headers) } == [nil] + realms.map { Self.basicHeader(user: $0) })
    }

    /// A server that names a fresh realm on every 401 stops being answered after twenty attempts.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func basicRetriesAreCappedAcrossRealms() async throws {
        let realms = (0 ..< 25).map { "lk-auth-\(UUID().uuidString)-\($0)" }
        let server = try FakeWebSocketServer(.upgradeResponses(realms.map(Self.basicChallenge)))
        defer { server.cancel() }
        let url = try await server.url()
        let stored = try realms.map { try Self.storeBasicCredential(url: url, realm: $0) }
        defer { for (space, credential) in stored {
            URLCredentialStorage.shared.remove(credential, for: space)
        } }

        let error = await #expect(throws: LiveKitError.self) { try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10) }
        #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == 401)
        #expect(server.requests.copy().count == 21)
    }

    private static func basicChallenge(_ realm: String) -> String {
        "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"\(realm)\"\r\n\r\n"
    }
}
