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

extension WebSocketLifecycleTests.StoredCredentials {
    @Test(arguments: [
        (["Basic realm=\"{realm}\""], true),
        (["Bearer realm=\"{realm}\"", "Basic realm=\"{realm}\""], true),
        (["Digest realm=\"{realm}\", nonce=\"n\", Basic realm=\"{realm}\""], false),
        (["Digest realm=\"{realm}\", nonce=\"n\"", "Basic realm=\"{realm}\""], false),
        (["Basic realm=\"{realm}\"", "Digest realm=\"{realm}\", nonce=\"n\""], false),
        (["NTLM", "Basic realm=\"{realm}\""], false),
        (["Negotiate", "Basic realm=\"{realm}\""], false),
    ])
    func basicChallengeSchemePreferenceMatchesURLSession(challenges: [String], opens: Bool) async throws {
        let realm = "lk-review-auth-\(UUID().uuidString)"
        let fields = challenges.map { "WWW-Authenticate: \($0.replacingOccurrences(of: "{realm}", with: realm))\r\n" }.joined()
        let server = try FakeWebSocketServer(.upgradeResponses([
            "HTTP/1.1 401 Unauthorized\r\n\(fields)\r\n", WebSocketLifecycleTests.successfulHTTPUpgrade,
        ]))
        defer { server.cancel() }
        let url = try await server.url()
        let stored = try WebSocketLifecycleTests.storeBasicCredential(url: url, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        if opens {
            let socket = try await LiveKit.WebSocket(url: url, headers: [("Authorization", "Bearer probe")], timeoutInterval: 10)
            defer { socket.close() }
            #expect(server.requests.copy().count == 2)
            #expect(WebSocketLifecycleTests.authorization(server.requestHeaders.copy()) == WebSocketLifecycleTests.basicHeader())
        } else {
            let error = await #expect(throws: LiveKitError.self) {
                try await LiveKit.WebSocket(url: url, headers: [("Authorization", "Bearer probe")], timeoutInterval: 10)
            }
            #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == 401)
            #expect(server.requests.copy().count == 1)
            #expect(server.requests.copy().allSatisfy { WebSocketLifecycleTests.authorization($0.headers) == "Bearer probe" })
        }
    }

    @Test(arguments: ["dIgEsT realm=\"{realm}\", nonce=\"n\"", "nTlM", "nEgOtIaTe YWJj=="])
    func strongerChallengeSchemeMatchingIsCaseInsensitive(challenge: String) throws {
        let realm = "lk-review-auth-\(UUID().uuidString)"
        let url = try #require(URL(string: "http://\(realm).invalid/rtc"))
        let stored = try WebSocketLifecycleTests.storeBasicCredential(url: url, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        let response = WebSocketUpgradeFailure(statusCode: 401, headers: [
            ("www-authenticate", "Basic realm=\"\(realm)\""),
            ("www-authenticate", challenge.replacingOccurrences(of: "{realm}", with: realm)),
        ])
        #expect(WebSocket.basicAuthorization(response, url: url) == nil)
    }

    @Test(arguments: [
        ("/basic-then-redirect", ["/ok?from=basic"], [true], true),
        ("/basic-then-redirect-host", ["ws://localhost:{port}/basic?from=host"], [false], false),
        ("/basic-then-redirect-http", ["http://127.0.0.1:{port}/ok?from=http-basic"], [false], true),
        ("/dir/sub/basic-then-up", ["/ok?from=up"], [false], true),
        ("/bounce-out", ["ws://localhost:{port}/bounce-back", "ws://127.0.0.1:{port}/basic?from=bounce"], [false, true], true),
    ])
    func basicRedirectProtectionSpaceMatchesURLSession(path: String, targets: [String], sendsBasic: [Bool], opens: Bool) async throws {
        let realm = "lk-redirect-scope-\(UUID().uuidString)"
        let redirects = targets.map { "HTTP/1.1 308 Redirect\r\nLocation: \($0)\r\n\r\n" }
        let challenge = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"\(realm)\"\r\n\r\n"
        let server = try FakeWebSocketServer(.upgradeResponses([challenge] + redirects + [opens ? WebSocketLifecycleTests.successfulHTTPUpgrade : challenge]))
        defer { server.cancel() }
        let origin = try await server.url()
        let url = try #require(URL(string: path, relativeTo: origin)?.absoluteURL)
        let stored = try WebSocketLifecycleTests.storeBasicCredential(url: url, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        if opens {
            let socket = try await LiveKit.WebSocket(url: url, headers: [("Authorization", "Bearer probe")], timeoutInterval: 10)
            socket.close()
        } else {
            let error = await #expect(throws: LiveKitError.self) {
                try await LiveKit.WebSocket(url: url, headers: [("Authorization", "Bearer probe")], timeoutInterval: 10)
            }
            #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == 401)
        }
        let basic = WebSocketLifecycleTests.basicHeader()
        let expected: [String?] = ["Bearer probe", basic] + sendsBasic.map { $0 ? basic : nil }
        #expect(server.requests.copy().map { WebSocketLifecycleTests.authorization($0.headers) } == expected)
    }
}

extension WebSocketLifecycleTests {
    @Test func basicProtectionSpaceUsesLiteralSchemeHostPortAndDirectory() throws {
        let source = try #require(URL(string: "ws://example.invalid/dir/sub/basic"))
        for raw in ["ws://EXAMPLE.invalid:80/dir/sub/next", "ws://example.invalid/dir/sub/deeper/ok?x=1"] {
            let target = try #require(URL(string: raw))
            #expect(WebSocket.isInBasicProtectionSpace(target, challengedURL: source))
        }
        for raw in ["http://example.invalid/dir/sub/next", "wss://example.invalid:80/dir/sub/next", "ws://example.invalid:81/dir/sub/next",
                    "ws://other.invalid/dir/sub/next", "ws://example.invalid/ok", "ws://example.invalid/dir/submarine/next"]
        {
            let target = try #require(URL(string: raw))
            #expect(!WebSocket.isInBasicProtectionSpace(target, challengedURL: source))
        }
        let secure = try #require(URL(string: "wss://example.invalid/basic"))
        let secureSame = try #require(URL(string: "wss://example.invalid:443/ok"))
        let secureHTTP = try #require(URL(string: "https://example.invalid:443/ok"))
        #expect(WebSocket.isInBasicProtectionSpace(secureSame, challengedURL: secure))
        #expect(!WebSocket.isInBasicProtectionSpace(secureHTTP, challengedURL: secure))
    }

    @Test(arguments: [401, 403])
    func rejectedUpgradeDoesNotExposeResponseMetadata(status: Int) async throws {
        let name = "lk-review-cookie-\(UUID().uuidString)"
        let cookieValue = "session-secret-\(UUID().uuidString)"
        let location = "/private?token=location-secret"
        let realm = "challenge-secret-\(UUID().uuidString)"
        let head = "HTTP/1.1 \(status) Rejected\r\nSet-Cookie: \(name)=\(cookieValue); Path=/\r\n"
            + "Location: \(location)\r\nWWW-Authenticate: Basic realm=\"\(realm)\"\r\nX-Private: other-secret\r\n\r\n"
        let server = try FakeWebSocketServer(.upgradeResponse(head: head))
        defer { server.cancel() }
        defer {
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == name {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        let error = await #expect(throws: LiveKitError.self) { try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10) }
        let rejection = try #require(error?.internalError as? WebSocketUpgradeFailure)
        #expect(rejection.statusCode == status)
        #expect(rejection.headers.isEmpty)
        let description = String(reflecting: error?.internalError)
        #expect(!description.contains(cookieValue))
        #expect(!description.contains(location))
        #expect(!description.contains(realm))
        #expect(!description.contains("other-secret"))
        #expect(HTTPCookieStorage.shared.cookies?.first { $0.name == name }?.value == cookieValue)
    }

    @Test func upgradeFailureRetainsOnlyRetryMetadataInternally() throws {
        let head = "HTTP/1.1 401 Unauthorized\r\nSet-Cookie: private=cookie-secret; Path=/\r\nX-Private: other-secret\r\n"
            + "Location: /retry\r\nWWW-Authenticate: Basic realm=\"test\"\r\n\r\n"
        guard case let .failed(error) = WebSocket.upgradeOutcome(Data(head.utf8), key: "unused") else {
            Issue.record("Expected the HTTP rejection")
            return
        }
        let rejection = try #require(error.internalError as? WebSocketUpgradeFailure)
        #expect(rejection.headers.map(\.name) == ["location", "www-authenticate"])
        #expect(!String(reflecting: rejection).contains("cookie-secret"))
        #expect(!String(reflecting: rejection).contains("other-secret"))
    }

    /// A peer advertising 8 bits sends a 300-byte reference that needs a larger receive window.
    @Test func eightBitServerWindowAcceptsWidenedHistory() async throws {
        let expected = try #require(Data(base64Encoded: "aelJV7OT3fUVHAKkOmFyfIfqw7dOjo9hXSHMwIpwLqSWWDfrExFMcXFYN0UrzkL31Z9riYx0lYJmYSVFWwAi38zx+cvyEXxtNS2n7C9uwQgy8S//AVgqocFU1RQfEMviLa8JkXzA23Ti4jTan5Iynyl3N6L+Ysgpd4Y7XemGjOZMyJ6SA/la9D9Xa54qMRSK4awnL4kNzkwhguVPFdLeW3Y+VQbW1mZQvpKRDuBlJ1fqRkny2y4Jz6ui/qAS278On7IQwV64RyjLwODGONPJI6w0LTWjQdXeAXjloO4mnQW2LtPEsdsaUv5JoX6b/ZdVPvlB+IZtbHMtjV6DEonl+HmW3Izb8YKAkfXg6wwjcBmJ7I7haloYIMK9rRRug/ewARx09ISm+p1MOl20"))
        let first = try #require(Data(base64Encoded: "ACwB0/5p6UlXs5Pd9RUcAqQ6YXJ8h+rDt06Oj2FdIczAinAupJZYN+sTEUxxcVg3RSvOQvfVn2uJjHSVgmZhJUVbACLfzPH5y/IRfG01LafsL27BCDLxL/8BWCqhwVTVFB8Qy+ItrwmRfMDbdOLiNNqfkjKfKXc3ov5iyCl3hjtd6YaM5kzInpID+Vr0P1drnioxFIrhrCcviQ3OTCGC5U8V0t5bdj5VBtbWZlC+kpEO4GUnV+pGSfLbLgnPq6L+oBLbvw6fshDBXrhHKMvA4MY408kjrDQtNaNB1d4BeOWg7iadBbYu08Sx2xpS/kmhfpv9l1U++UH4hm1scy2NXoMSieX4eZbcjNvxgoCR9eDrDCNwGYnsjuFqWhggwr2tFG6D97ABHHT0hKb6nUw6XbQA"))
        let second = try #require(Data(base64Encoded: "yhwNK6LDCgA="))
        let head = Self.successfulHTTPUpgrade.replacingOccurrences(of: "\r\n\r\n",
                                                                   with: "\r\nSec-WebSocket-Extensions: permessage-deflate; server_max_window_bits=8\r\n\r\n")
        let server = try FakeWebSocketServer(.upgradeResponse(head: head, then: FakeWebSocketServer.frame(0x42, first)
                + FakeWebSocketServer.frame(0x42, second)))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        let iterator = socket.makeAsyncIterator()
        for _ in 0 ..< 2 {
            guard case let .data(data)? = try await iterator.next() else {
                Issue.record("Missing a message using the widened server window")
                return
            }
            #expect(data == expected)
        }
        socket.close()
        try await server.served.wait()
    }
}
