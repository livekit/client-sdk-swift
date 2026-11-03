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
import LiveKitFFI
import Testing

extension WebSocketLifecycleTests {
    @Test func alreadyCancelledConnectOpensNoConnection() async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let url = try await server.url()
        let teardowns = StateSync(0)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                withUnsafeCurrentTask { $0?.cancel() }
                let error = await #expect(throws: LiveKitError.self) {
                    try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10, onEvent: { event in
                        if case .teardown = event { teardowns.mutate { $0 += 1 } }
                    })
                }
                #expect(error?.type == .cancelled)
            }
        }
        #expect(teardowns.copy() == 0)
        #expect(server.acceptCount.copy() == 0)
        // Prove the listener accepts a subsequent connect from a task that is not cancelled.
        let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
        socket.close()
        _ = try await server.clientGone.wait()
        #expect(server.acceptCount.copy() == 1)
    }

    @Test(arguments: [false, true])
    func tlsOffersHTTP11(redirect: Bool) async throws {
        let server = try FakeWebSocketServer(.tlsClientHello)
        defer { server.cancel() }
        var components = try #require(await URLComponents(url: server.url(), resolvingAgainstBaseURL: false))
        components.scheme = "wss"
        let secureURL = try #require(components.url)
        let redirector = try FakeWebSocketServer(.upgradeResponse(head: "HTTP/1.1 302 Redirect\r\nLocation: \(secureURL.absoluteString)\r\n\r\n"))
        defer { redirector.cancel() }
        let url = try await redirect ? redirector.url() : secureURL
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let socket = try? await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 5)
                socket?.close()
            }
            let hello = try await server.clientHello.wait()
            #expect(redirector.acceptCount.copy() == (redirect ? 1 : 0))
            #expect(server.acceptCount.copy() == 1)
            #expect(hello.first == 0x16) // TLS handshake record.
            // ALPN extension 0x0010, length 11: a length-prefixed list containing only "http/1.1".
            let alpn = Data([0x00, 0x10, 0x00, 0x0B, 0x00, 0x09, 0x08]) + Data("http/1.1".utf8)
            #expect(hello.range(of: alpn) != nil)
            // ClientHello: record header (5), handshake header (4), version (2), random (32), session ID.
            let sessionIDLength = try #require(hello.dropFirst(43).first)
            let cipherBytes = Array(hello.dropFirst(44 + Int(sessionIDLength)))
            try #require(cipherBytes.count >= 2)
            let length = Int(cipherBytes[0]) << 8 | Int(cipherBytes[1])
            try #require(length > 0 && length.isMultiple(of: 2) && cipherBytes.count >= 2 + length)
            let offered = Set(stride(from: 2, to: 2 + length, by: 2).map { UInt16(cipherBytes[$0]) << 8 | UInt16(cipherBytes[$0 + 1]) })
                .filter { $0 != 0x00FF && !($0 & 0x0F0F == 0x0A0A && $0 >> 8 == $0 & 0xFF) } // SCSV and GREASE are not ciphers.
            let forwardSecret: Set<UInt16> = [
                0x1301, 0x1302, 0x1303, // TLS 1.3.
                0xC009, 0xC00A, 0xC013, 0xC014, 0xC023, 0xC024, 0xC027, 0xC028, // ECDHE + AES CBC.
                0xC02B, 0xC02C, 0xC02F, 0xC030, 0xCCA8, 0xCCA9, // ECDHE + AES GCM or ChaCha20.
            ]
            #expect(!offered.isEmpty)
            #expect(offered.isSubset(of: forwardSecret))
            group.cancelAll()
        }
    }

    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func closeRacingSendPreservesFrameOrder() async throws {
        for round in 0 ..< 150 {
            let server = try FakeWebSocketServer(.idle)
            defer { server.cancel() }
            let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
            let ready = AsyncCompleter<Void>(label: "race.ready", defaultTimeout: 5)
            let start = AsyncCompleter<Void>(label: "race.start", defaultTimeout: 5)
            let sent = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    ready.resume(returning: ())
                    try await start.wait()
                    do {
                        try await socket.send(data: Data([0x01]))
                        return true
                    } catch {
                        #expect((error as? LiveKitError)?.type == .network)
                        #expect(((error as? LiveKitError)?.internalError as? URLError)?.code == .cancelled)
                        return false
                    }
                }
                try await ready.wait()
                start.resume(returning: ())
                for _ in 0 ..< round % 75 {
                    await Task.yield()
                }
                socket.close()
                return try await group.next() ?? false
            }
            _ = try await server.clientGone.wait()
            let opcodes = server.frames.read { $0.map(\.opcode) }
            #expect(opcodes == (sent ? [0x2, 0x8] : [0x8]), "Round \(round)")
        }
    }

    @Test func serverCloseEndsPendingReceive() async throws {
        let server = try FakeWebSocketServer(.closeFrame)
        defer { server.cancel() }
        let registered = AsyncCompleter<Void>(label: "serverClose.receiveRegistered", defaultTimeout: 5)
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10, onEvent: { event in
            if case .receiveRegistered = event { registered.resume(returning: ()) }
        })
        let reader = Task { try await socket.makeAsyncIterator().next() }
        try await registered.wait()
        try await socket.send(data: Data([0x01]))
        let error = await #expect(throws: LiveKitError.self) { try await reader.value }
        #expect((error?.internalError as? WebSocketClosedByPeer)?.code == 1000)
        try await server.served.wait()
    }

    @Test(arguments: [false, true])
    func sendAfterCloseIsCancelled(afterTeardown: Bool) async throws {
        let server = try FakeWebSocketServer(.unansweredClose)
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        socket.close()
        if afterTeardown { _ = try await server.clientGone.wait() }

        let error = await #expect(throws: LiveKitError.self) { try await socket.send(data: Data([0x01])) }
        #expect(error?.type == .network)
        #expect((error?.internalError as? URLError)?.code == .cancelled)
        #expect(error?.asTransportError == .Closed)
        _ = try await server.clientGone.wait()
        #expect(server.frames.read { $0.map(\.opcode) } == [0x8])
    }

    @Test(arguments: ["Cookie", "cOoKiE"])
    func callerCookieOverridesStorage(header: String) async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "lk-test-\(UUID().uuidString)", .value: "stored",
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let headers = [(name: header, value: "caller=one"), (name: "cookie", value: "other=two")]
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: headers, timeoutInterval: 10)
        defer { socket.close() }
        let lines = server.requestHeaders.copy().filter { $0.lowercased().hasPrefix("cookie:") }
        #expect(lines.map { $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) } == ["caller=one; other=two"])
    }

    @Test func hostHeaderDropsZoneID() throws {
        let url = try #require(URL(string: "ws://[fe80::1%25en0]:7880/rtc"))
        let host = WebSocket.upgradeHeaders(url: url, headers: []).last
        #expect(host?.name == "Host")
        #expect(host?.value == "[fe80::1]:7880")
    }

    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func invalidCallerHeaderFailsBeforeConnecting() async throws {
        let server = try FakeWebSocketServer(.blackhole)
        defer { server.cancel() }
        let error = await #expect(throws: LiveKitError.self) {
            try await LiveKit.WebSocket(url: server.url(), headers: [("X-Test", "a\nb")], timeoutInterval: 10)
        }
        #expect(error?.type == .invalidParameter)
        #expect(server.acceptCount.copy() == 0)
    }

    /// A line break in a header would end it and start one that the caller did not write.
    @Test(arguments: ["a\r\nX-Injected: b", "a\nb"])
    func upgradeRequestRefusesLineBreaks(value: String) throws {
        let url = try #require(URL(string: "ws://127.0.0.1:7880/rtc"))
        let error = #expect(throws: LiveKitError.self) {
            try WebSocket.upgradeRequest(url: url, key: WebSocket.upgradeKey(), headers: [(name: "X-Test", value: value)])
        }
        #expect(error?.type == .invalidParameter)
    }
}
