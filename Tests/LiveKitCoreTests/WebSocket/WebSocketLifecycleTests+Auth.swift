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
    @Test(arguments: [false, true], [false, true])
    func basicChallengeUsesDefaultCredential(afterBearer: Bool, quoted: Bool) async throws {
        let realm = "lk-auth-\(UUID().uuidString)"
        let cookie = "lk-auth-cookie-\(UUID().uuidString)"
        let value = quoted ? "\"\(realm)\"" : realm
        let challenge = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\(value)\r\nSet-Cookie: \(cookie)=stored; Path=/\r\n\r\n"
        let server = try FakeWebSocketServer(.upgradeResponses([challenge, Self.successfulHTTPUpgrade]))
        defer { server.cancel() }
        let url = try await server.url()
        let stored = try Self.storeBasicCredential(url: url, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        defer {
            for value in HTTPCookieStorage.shared.cookies ?? [] where value.name == cookie {
                HTTPCookieStorage.shared.deleteCookie(value)
            }
        }
        let headers = afterBearer ? [(name: "aUtHoRiZaTiOn", value: "Bearer probe")] : []
        let socket = try await LiveKit.WebSocket(url: url, headers: headers, timeoutInterval: 10)
        defer { socket.close() }
        let requests = server.requests.copy()
        #expect(requests.count == 2)
        #expect(Self.authorization(requests.first?.headers) == (afterBearer ? "Bearer probe" : nil))
        #expect(Self.authorization(requests.last?.headers) == "Basic cHJvYmU6c2VjcmV0")
        #expect(requests.last?.headers.contains { $0.hasPrefix("Cookie:") && $0.contains("\(cookie)=stored") } == true)
    }

    @Test func rejectedBasicCredentialRetriesOnlyOnce() async throws {
        let realm = "lk-auth-\(UUID().uuidString)"
        let server = try FakeWebSocketServer(.upgradeResponse(head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"\(realm)\"\r\n\r\n"))
        defer { server.cancel() }
        let url = try await server.url()
        let stored = try Self.storeBasicCredential(url: url, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        let error = await #expect(throws: LiveKitError.self) {
            try await LiveKit.WebSocket(url: url, headers: [("Authorization", "Bearer probe")], timeoutInterval: 10)
        }
        #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == 401)
        let requests = server.requests.copy()
        #expect(requests.count == 2)
        #expect(Self.authorization(requests.first?.headers) == "Bearer probe")
        #expect(Self.authorization(requests.last?.headers) == "Basic cHJvYmU6c2VjcmV0")
    }

    @Test(arguments: ["none", "realm", "scheme", "port", "host"])
    func basicChallengeDoesNotUseUnmatchedCredentials(scope: String) async throws {
        let realm = "lk-auth-\(UUID().uuidString)"
        let server = try FakeWebSocketServer(.upgradeResponse(head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"\(realm)\"\r\n\r\n"))
        defer { server.cancel() }
        let url = try await server.url()
        let stored = scope == "none" ? nil : try Self.storeBasicCredential(url: url, realm: realm, scope: scope)
        defer { if let stored { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) } }
        let error = await #expect(throws: LiveKitError.self) { try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10) }
        #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == 401)
        #expect(server.requests.copy().count == 1)
        #expect(Self.authorization(server.requestHeaders.copy()) == nil)
    }

    @Test(arguments: [(401, "Digest realm=\"{realm}\", nonce=\"x\""), (401, "Bearer realm=\"{realm}\""),
                      (407, "Basic realm=\"{realm}\""), (401, "Basic"), (401, "Basic realm=\"unterminated"),
                      (401, "Basic unknown=ignored, This is realm=\"{realm}\"")])
    func nonBasicOrInvalidChallengeDoesNotRetry(status: Int, challenge: String) async throws {
        let realm = "lk-auth-\(UUID().uuidString)"
        let field = status == 407 ? "Proxy-Authenticate" : "WWW-Authenticate"
        let value = challenge.replacingOccurrences(of: "{realm}", with: realm)
        let server = try FakeWebSocketServer(.upgradeResponse(head: "HTTP/1.1 \(status) Response\r\n\(field): \(value)\r\n\r\n"))
        defer { server.cancel() }
        let url = try await server.url()
        let stored = try Self.storeBasicCredential(url: url, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        let error = await #expect(throws: LiveKitError.self) { try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10) }
        #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == status)
        #expect(server.requests.copy().count == 1)
    }

    @Test(arguments: ["plain", "space and, comma", "quote\" and \\slash"], ["standard", "charset-first", "combined"])
    func basicChallengeParsesQuotedRealmsAndParameters(suffix: String, format: String) async throws {
        let realm = "lk-auth-\(UUID().uuidString)-\(suffix)"
        let escaped = realm.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let challenge = switch format {
        case "charset-first": "bAsIc ChArSeT=\"UTF-8\", ReAlM=\"\(escaped)\""
        case "combined": "Digest realm=\"other, Basic realm=wrong\", nonce=\"x\", Basic unknown=ignored, realm=\"\(escaped)\""
        default: "Basic realm=\"\(escaped)\""
        }
        let server = try FakeWebSocketServer(.upgradeResponses([
            "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: \(challenge)\r\n\r\n", Self.successfulHTTPUpgrade,
        ]))
        defer { server.cancel() }
        let url = try await server.url()
        let stored = try Self.storeBasicCredential(url: url, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
        defer { socket.close() }
        #expect(server.requests.copy().count == 2)
        #expect(Self.authorization(server.requestHeaders.copy()) == "Basic cHJvYmU6c2VjcmV0")
    }

    @Test(arguments: ["ws", "wss", "http", "https"])
    func basicCredentialUsesHTTPProtectionSpaceAndDefaultPort(scheme: String) throws {
        let realm = "lk-auth-\(UUID().uuidString)"
        let url = try #require(URL(string: "\(scheme)://\(realm).invalid/rtc"))
        let stored = try Self.storeBasicCredential(url: url, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        let response = WebSocketUpgradeFailure(statusCode: 401, headers: [("www-authenticate", "Basic realm=\"\(realm)\"")])
        #expect(WebSocket.basicAuthorization(response, url: url) == "Basic cHJvYmU6c2VjcmV0")
    }

    @Test func redirectAfterBasicDropsCredential() async throws {
        let realm = "lk-auth-\(UUID().uuidString)"
        let target = try FakeWebSocketServer(.idle)
        defer { target.cancel() }
        let destination = try await target.url()
        let server = try FakeWebSocketServer(.upgradeResponses([
            "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"\(realm)\"\r\n\r\n",
            "HTTP/1.1 302 Redirect\r\nLocation: \(destination)\r\n\r\n",
        ]))
        defer { server.cancel() }
        let url = try await server.url()
        let stored = try Self.storeBasicCredential(url: url, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        let socket = try await LiveKit.WebSocket(url: url, headers: [("Authorization", "Bearer probe")], timeoutInterval: 10)
        defer { socket.close() }
        #expect(server.requests.copy().count == 2)
        #expect(Self.authorization(server.requestHeaders.copy()) == "Basic cHJvYmU6c2VjcmV0")
        #expect(Self.authorization(target.requestHeaders.copy()) == nil)
    }

    @Test func basicChallengeAfterRedirectUsesTargetCredential() async throws {
        let realm = "lk-auth-\(UUID().uuidString)"
        let target = try FakeWebSocketServer(.upgradeResponses([
            "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"\(realm)\"\r\n\r\n", Self.successfulHTTPUpgrade,
        ]))
        defer { target.cancel() }
        let destination = try await target.url()
        let stored = try Self.storeBasicCredential(url: destination, realm: realm)
        defer { URLCredentialStorage.shared.remove(stored.credential, for: stored.space) }
        let server = try FakeWebSocketServer(.upgradeResponse(head: "HTTP/1.1 302 Redirect\r\nLocation: \(destination)\r\n\r\n"))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [("Authorization", "Bearer probe")], timeoutInterval: 10)
        defer { socket.close() }
        let requests = target.requests.copy()
        #expect(requests.count == 2)
        #expect(Self.authorization(requests.first?.headers) == nil)
        #expect(Self.authorization(requests.last?.headers) == "Basic cHJvYmU6c2VjcmV0")
    }
}

private extension WebSocketLifecycleTests {
    static func storeBasicCredential(url: URL, realm: String, scope: String = "matching") throws -> (space: URLProtectionSpace, credential: URLCredential) {
        let host = try #require(url.host)
        let secure = ["wss", "https"].contains(url.scheme ?? "")
        let port = url.port ?? (secure ? 443 : 80)
        let space = URLProtectionSpace(host: scope == "host" ? "other.invalid" : host,
                                       port: scope == "port" ? (port == 65535 ? 1 : port + 1) : port,
                                       protocol: scope == "scheme" ? (secure ? "http" : "https") : (secure ? "https" : "http"),
                                       realm: scope == "realm" ? realm + "-other" : realm,
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let credential = URLCredential(user: "probe", password: "secret", persistence: .forSession)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: space)
        return (space, credential)
    }

    static func authorization(_ headers: [String]?) -> String? {
        headers?.first { $0.lowercased().hasPrefix("authorization:") }?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
    }
}
