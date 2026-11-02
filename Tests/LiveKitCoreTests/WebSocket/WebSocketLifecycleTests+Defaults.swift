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
    @Test func upgradeSendsDefaultAcceptHeaders() async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        defer { socket.close() }
        let headers = server.requestHeaders.copy()
        #expect(headers.filter { $0.lowercased().hasPrefix("accept:") } == ["Accept: */*"])
        #expect(headers.filter { $0.lowercased().hasPrefix("accept-encoding:") } == ["Accept-Encoding: gzip, deflate"])
    }

    @Test(arguments: [("Accept", "Accept-Encoding"), ("aCcEpT", "aCcEpT-eNcOdInG")])
    func callerAcceptHeadersOverrideDefaults(accept: String, encoding: String) async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [(accept, "application/octet-stream"), (encoding, "identity")],
                                                 timeoutInterval: 10)
        defer { socket.close() }
        let headers = server.requestHeaders.copy()
        #expect(headers.filter { $0.lowercased().hasPrefix("accept:") } == ["\(accept): application/octet-stream"])
        #expect(headers.filter { $0.lowercased().hasPrefix("accept-encoding:") } == ["\(encoding): identity"])
    }

    @Test(arguments: [101, 401, 403])
    func responseCookiesAreStoredBeforeOpenCompletes(status: Int) async throws {
        let prefix = "lk-defaults-\(UUID().uuidString)"
        var head = "HTTP/1.1 \(status) Response\r\n"
        if status == 101 {
            head += "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n"
        }
        head += "Set-Cookie: \(prefix)-a=one; Path=/\r\n"
            + "sEt-CoOkIe: \(prefix)-b=two; Path=/; Expires=Wed, 09 Jun 2038 10:18:14 GMT\r\n\r\n"
        let server = try FakeWebSocketServer(.upgradeResponse(head: head))
        defer { server.cancel() }
        let url = try await server.url()
        let storage = HTTPCookieStorage.shared
        defer {
            for cookie in storage.cookies ?? [] where cookie.name.hasPrefix(prefix) {
                storage.deleteCookie(cookie)
            }
        }
        if status == 101 {
            let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
            socket.close()
        } else {
            let error = await #expect(throws: LiveKitError.self) {
                try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
            }
            #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == status)
        }
        let cookies = storage.cookies ?? []
        #expect(cookies.first { $0.name == "\(prefix)-a" }?.value == "one")
        #expect(cookies.first { $0.name == "\(prefix)-b" }?.value == "two")
        let outgoing = WebSocket.upgradeHeaders(url: url, headers: []).first { $0.name == "Cookie" }?.value ?? ""
        #expect(outgoing.contains("\(prefix)-a=one"))
        #expect(outgoing.contains("\(prefix)-b=two"))
    }

    @Test func secureResponseCookieUsesHTTPSURL() throws {
        let name = "lk-defaults-\(UUID().uuidString)"
        let url = try #require(URL(string: "wss://\(name).invalid/rtc"))
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSet-Cookie: \(name)=secure; Secure; Path=/\r\n\r\n"
        let storage = HTTPCookieStorage.shared
        defer {
            for cookie in storage.cookies ?? [] where cookie.name == name {
                storage.deleteCookie(cookie)
            }
        }
        guard case .opened = WebSocket.upgradeOutcome(Data(head.utf8), key: key, url: url) else {
            Issue.record("The valid upgrade failed")
            return
        }
        let cookie = try #require(storage.cookies?.first { $0.name == name })
        #expect(cookie.isSecure)
        #expect(WebSocket.upgradeHeaders(url: url, headers: []).contains { $0.name == "Cookie" && $0.value == "\(name)=secure" })
        let cleartext = try #require(URL(string: "ws://\(name).invalid/rtc"))
        #expect(!WebSocket.upgradeHeaders(url: cleartext, headers: []).contains { $0.name == "Cookie" })
    }
}
