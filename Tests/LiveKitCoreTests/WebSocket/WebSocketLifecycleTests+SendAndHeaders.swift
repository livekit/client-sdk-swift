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

    @Test func tlsOffersHTTP11() async throws {
        let server = try FakeWebSocketServer(.tlsClientHello)
        defer { server.cancel() }
        var components = try #require(await URLComponents(url: server.url(), resolvingAgainstBaseURL: false))
        components.scheme = "wss"
        let url = try #require(components.url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let socket = try? await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 5)
                socket?.close()
            }
            let hello = try await server.clientHello.wait()
            #expect(hello.first == 0x16) // TLS handshake record.
            // ALPN extension 0x0010, length 11: a length-prefixed list containing only "http/1.1".
            let alpn = Data([0x00, 0x10, 0x00, 0x0B, 0x00, 0x09, 0x08]) + Data("http/1.1".utf8)
            #expect(hello.range(of: alpn) != nil)
            group.cancelAll()
        }
    }

    @Test func closeRacingSendPreservesFrameOrder() async throws {
        for round in 0 ..< 150 {
            let server = try FakeWebSocketServer(.idle)
            defer { server.cancel() }
            let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
            let gate = StateSync(0)
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            let sent = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    gate.mutate { $0 += 1 }
                    while gate.copy() < 2, DispatchTime.now().uptimeNanoseconds < deadline {}
                    do {
                        try await socket.send(data: Data([0x01]))
                        return true
                    } catch {
                        #expect((error as? LiveKitError)?.type == .network)
                        #expect(((error as? LiveKitError)?.internalError as? URLError)?.code == .cancelled)
                        return false
                    }
                }
                gate.mutate { $0 += 1 }
                while gate.copy() < 2, DispatchTime.now().uptimeNanoseconds < deadline {}
                for _ in 0 ..< round % 75 {
                    _ = gate.copy()
                }
                socket.close()
                return await group.next() ?? false
            }
            #expect(gate.copy() == 2)
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

    @Test(arguments: [1, 5])
    func queuedMessagesBeforeCloseAreDelivered(count: Int) async throws {
        let server = try FakeWebSocketServer(.messagesBeforeClose(count: count))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))
        try await server.served.wait()

        var received: [Data] = []
        var receiveError: Error?
        do {
            for try await message in socket {
                if case let .data(data) = message { received.append(data) }
            }
        } catch {
            receiveError = error
        }
        withKnownIssue("Queued messages lost after a server Close frame") {
            #expect(received == (0 ..< count).map { Data([UInt8($0)]) })
        } matching: { issue in
            if case .expectationFailed = issue.kind { return true }
            return false
        }
        let endedWithENOTCONN = Self.isNotConnected(receiveError)
        withKnownIssue("ENOTCONN after a server Close frame instead of a clean end") {
            #expect(receiveError == nil)
        } matching: { issue in
            guard case .expectationFailed = issue.kind else { return false }
            return endedWithENOTCONN
        }
    }
}

extension WebSocketLifecycleTests {
    static func isNotConnected(_ error: Error?) -> Bool {
        guard let error = error as? LiveKitError, error.type == .network,
              let underlying = error.internalError as NSError?
        else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOTCONN)
    }
}
