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
    @Test(arguments: [301, 302, 303, 307, 308], ["Authorization", "aUtHoRiZaTiOn"])
    func redirectDropsAuthorizationAndRebuildsHost(status: Int, authorization: String) async throws {
        let target = try FakeWebSocketServer(.idle)
        defer { target.cancel() }
        let targetURL = try await target.url()
        var components = try #require(URLComponents(url: targetURL, resolvingAgainstBaseURL: false))
        components.path = "/next"
        components.percentEncodedQuery = "value=one%20two"
        let destination = try #require(components.url)
        let server = try FakeWebSocketServer(.upgradeResponse(head: "HTTP/1.1 \(status) Redirect\r\nLocation: \(destination.absoluteString)\r\n\r\n"))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [(authorization, "Bearer probe"), ("Cookie", "caller=explicit"),
                                                                              ("Accept", "application/cbor"), ("Accept-Encoding", "identity"),
                                                                              ("X-Probe", "custom"), ("Host", "wrong.invalid")], timeoutInterval: 10)
        defer { socket.close() }
        #expect(server.acceptCount.copy() == 1)
        #expect(target.acceptCount.copy() == 1)
        let headers = target.requestHeaders.copy()
        #expect(!headers.contains { $0.lowercased().hasPrefix("authorization:") })
        #expect(headers.contains("Cookie: caller=explicit"))
        #expect(headers.contains("Accept: application/cbor"))
        #expect(headers.contains("Accept-Encoding: identity"))
        #expect(headers.contains("X-Probe: custom"))
        #expect(try headers.contains("Host: 127.0.0.1:\(#require(destination.port))"))
        #expect(target.requests.copy().first?.line == "GET /next?value=one%20two HTTP/1.1")
    }

    @Test func relativeRedirectUsesResponseCookies() async throws {
        let name = "lk-redirect-\(UUID().uuidString)"
        let server = try FakeWebSocketServer(.upgradeResponses([
            "HTTP/1.1 302 Redirect\r\nLocation: ../next?escaped=one%20two\r\nSet-Cookie: \(name)=stored; Path=/\r\n\r\n",
            Self.successfulHTTPUpgrade,
        ]))
        defer { server.cancel() }
        defer {
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == name {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        defer { socket.close() }
        let requests = server.requests.copy()
        #expect(requests.count == 2)
        #expect(requests.last?.line == "GET /next?escaped=one%20two HTTP/1.1")
        #expect(requests.last?.headers.contains { $0.hasPrefix("Cookie:") && $0.contains("\(name)=stored") } == true)
    }

    @Test func redirectLimitMatchesURLSession() async throws {
        let server = try FakeWebSocketServer(.upgradeResponse(head: "HTTP/1.1 302 Redirect\r\nLocation: /again\r\n\r\n"))
        defer { server.cancel() }
        let teardowns = StateSync(0)
        let error = await #expect(throws: LiveKitError.self) {
            try await LiveKit.WebSocket(url: server.url(), headers: [("Authorization", "Bearer probe")], timeoutInterval: 10, onEvent: { event in
                if case .teardown = event { teardowns.mutate { $0 += 1 } }
            })
        }
        #expect((error?.internalError as? URLError)?.code == .httpTooManyRedirects)
        #expect(server.acceptCount.copy() == 21)
        #expect(server.requests.copy().count == 21)
        #expect(teardowns.copy() == 21)
        #expect(server.requests.copy().dropFirst().allSatisfy { request in
            !request.headers.contains { $0.lowercased().hasPrefix("authorization:") }
        })
    }

    @Test(arguments: [(302, false), (300, true), (304, true), (401, true)])
    func nonRedirectOrMissingLocationKeepsStatus(status: Int, location: Bool) async throws {
        let target = try FakeWebSocketServer(.idle)
        defer { target.cancel() }
        let header = try await location ? "Location: \(target.url())\r\n" : ""
        let server = try FakeWebSocketServer(.upgradeResponse(head: "HTTP/1.1 \(status) Response\r\n\(header)\r\n"))
        defer { server.cancel() }
        let error = await #expect(throws: LiveKitError.self) { try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10) }
        #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == status)
        #expect(target.acceptCount.copy() == 0)
        #expect(server.acceptCount.copy() == 1)
    }

    @Test(arguments: ["ws", "wss", "http", "https"], ["ws", "wss", "http", "https"])
    func redirectAllowsHTTPAndWebSocketSchemes(source: String, target: String) throws {
        let url = try #require(URL(string: "\(source)://source.invalid/rtc"))
        let response = WebSocketUpgradeFailure(statusCode: 302, headers: [("location", "\(target)://target.invalid:7880/next?x=one%20two")])
        let result = try #require(try WebSocket.redirectedURL(response, from: url))
        #expect(result.scheme == (["wss", "https"].contains(target) ? "wss" : "ws"))
        #expect(result.host == "target.invalid")
        #expect(result.port == 7880)
        #expect(result.query == "x=one%20two")
    }

    @Test(arguments: ["file", "ftp", "data"])
    func redirectRejectsNonHTTPSchemes(scheme: String) throws {
        let url = try #require(URL(string: "ws://source.invalid/rtc"))
        let response = WebSocketUpgradeFailure(statusCode: 302, headers: [("location", "\(scheme)://target.invalid/next")])
        let error = #expect(throws: LiveKitError.self) { try WebSocket.redirectedURL(response, from: url) }
        #expect((error?.internalError as? URLError)?.code == .unsupportedURL)
    }

    @Test func cancellationDuringRedirectClosesBothConnections() async throws {
        let target = try FakeWebSocketServer(.blackhole)
        defer { target.cancel() }
        let server = try await FakeWebSocketServer(.upgradeResponse(head: "HTTP/1.1 302 Redirect\r\nLocation: \(target.url())\r\n\r\n"))
        defer { server.cancel() }
        let url = try await server.url()
        let teardowns = StateSync(0)
        let task = Task {
            try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10, onEvent: { event in
                if case .teardown = event { teardowns.mutate { $0 += 1 } }
            })
        }
        try await target.accepted.wait()
        task.cancel()
        let error = await #expect(throws: LiveKitError.self) { try await task.value }
        #expect(error?.type == .cancelled)
        #expect(teardowns.copy() == 2)
    }

    static var successfulHTTPUpgrade: String {
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
    }
}
