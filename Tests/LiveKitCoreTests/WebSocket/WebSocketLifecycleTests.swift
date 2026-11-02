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

import Darwin
import Foundation
@testable import LiveKit
import Network
import Testing

/// How the socket is closed: `close()`, a cancelled read (how `SignalClient.cleanUp` ends it first), or the last
/// reference going away (`deinit`).
enum ClosePath: Sendable, CaseIterable {
    case close
    case cancelledRead
    case release
}

/// How iteration over the socket ends.
enum Ending: Sendable, CustomTestStringConvertible {
    /// Every message before a close frame is delivered, then the close frame fails the stream with its code.
    case closedByPeer(code: UInt16)
    case networkError(posix: Int32?)

    var testDescription: String {
        switch self {
        case let .closedByPeer(code): "closed by the peer (\(code))"
        case let .networkError(posix): "network error\(posix.map { " POSIX \($0)" } ?? "")"
        }
    }
}

/// The signalling socket's lifecycle against a server that is not a LiveKit server: how it opens, how it fails to,
/// and how its message sequence ends for each way a peer can go away.
@Suite(.tags(.networking), TestLimits.unit)
struct WebSocketLifecycleTests {
    private static let headers = [(name: "Authorization", value: "Bearer test")]
    /// How long `close()` waits for the server's answer, in nanoseconds.
    private static let closeLimit: UInt64 = 250_000_000

    // MARK: - Opening

    @Test func ownCloseEndsTheSequence() async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let events = SocketEvents()
        let socket = try await Self.open(server, events: events)
        let reader = Task { try await Self.messageCount(of: socket) }
        try await events.receiveRegistered.wait()
        socket.close()
        #expect(try await reader.value == 0)
    }

    /// As URLSession's `cancel(with: .normalClosure)`: the server sees a normal disconnect, and then the client drops the
    /// connection, whichever way the socket closes.
    @Test(arguments: ClosePath.allCases)
    func closeSendsNormalClosure(path: ClosePath) async throws {
        let server = try FakeWebSocketServer(.unansweredClose)
        defer { server.cancel() }
        let events = SocketEvents()
        var socket: LiveKit.WebSocket? = try await Self.open(server, events: events)
        switch path {
        case .close:
            socket?.close()
            socket?.close()
        case .cancelledRead:
            let reading = try #require(socket)
            let reader = Task { try await Self.messageCount(of: reading) }
            try await events.receiveRegistered.wait()
            reader.cancel()
            #expect(try await reader.value == 0)
        case .release:
            socket = nil
        }
        _ = try await server.clientGone.wait()
        try await events.closeDeadline.wait()
        #expect(events.teardowns.copy() == 1)
        #expect(server.frames.read { $0.filter { $0.opcode == 0x8 }.count } == 1)
        let close = server.frames.read { $0.last }
        #expect(close?.opcode == 0x8)
        #expect(close?.payload == Data([0x03, 0xE8]))
    }

    @Test(arguments: [FakeWebSocketServer.Behavior.idle, .messageBeforeCloseAnswer, .closeAnswerAtDeadline, .unansweredClose])
    func closeWithPendingReadTearsDownOnce(behavior: FakeWebSocketServer.Behavior) async throws {
        let server = try FakeWebSocketServer(behavior)
        defer { server.cancel() }
        let events = SocketEvents()
        let socket = try await Self.open(server, events: events)
        let reader = Task { try await Self.messageCount(of: socket) }
        try await events.receiveRegistered.wait()

        socket.close()
        socket.close()
        #expect(try await reader.value == 0)
        _ = try await server.clientGone.wait()
        try await events.closeDeadline.wait()
        #expect(events.teardowns.copy() == 1)
        #expect(server.frames.read { $0.filter { $0.opcode == 0x8 }.count } == 1)
        #expect(await socket.connection.stateUpdateHandler == nil)
    }

    @Test func promptCloseAnswerEndsBeforeTheLimit() async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let socket = try await Self.open(server)
        let start = DispatchTime.now().uptimeNanoseconds
        socket.close()
        let gone = try await server.clientGone.wait()
        let answered = try #require(server.closeAnswered.copy())
        #expect(gone >= answered)
        #expect(gone < start + Self.closeLimit)
    }

    /// A message that the server sends before it answers our close frame does not end the wait: the client drops the
    /// connection after the answer, or at the 250 ms limit if the answer comes later than that.
    @Test func closeWaitsPastAMessageForTheAnswer() async throws {
        let server = try FakeWebSocketServer(.messageBeforeCloseAnswer)
        defer { server.cancel() }
        let socket = try await Self.open(server)
        let start = DispatchTime.now().uptimeNanoseconds
        socket.close()
        let gone = try await server.clientGone.wait()
        let answered = try #require(server.closeAnswered.copy())
        #expect(gone >= answered)
        #expect(gone < start + Self.closeLimit)
    }

    /// With no answer the client drops the connection at the 250 ms limit and within one second.
    @Test func unansweredCloseEndsAtTheLimit() async throws {
        let server = try FakeWebSocketServer(.unansweredClose)
        defer { server.cancel() }
        let socket = try await Self.open(server)
        let start = DispatchTime.now().uptimeNanoseconds
        socket.close()
        let gone = try await server.clientGone.wait()
        #expect(gone >= start + Self.closeLimit)
        #expect(gone < start + 1_000_000_000)
    }

    /// Network.framework's own `Host` has no port and no IPv6 brackets, and `setAdditionalHeaders` keeps only the last
    /// value of a repeated name.
    @Test(arguments: ["127.0.0.1", "[::1]"])
    func upgradeHeaders(host: String) async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let url = try await server.url(host: host)
        let headers = Self.headers + [(name: "X-Repeated", value: "a"), (name: "x-repeated", value: "b"), (name: "Host", value: "caller")]
        _ = try await LiveKit.WebSocket(url: url, headers: headers, timeoutInterval: 10)

        let port = try #require(url.port)
        let lines = server.requestHeaders.copy()
        #expect(lines.filter { $0.lowercased().hasPrefix("host:") } == ["Host: \(host):\(port)"])
        #expect(lines.contains("X-Repeated: a,b"))
    }

    /// URLSessionWebSocketTask's limit on a received message.
    @Test(arguments: [1 << 20, (1 << 20) + 1])
    func maximumMessageSize(size: Int) async throws {
        let server = try FakeWebSocketServer(.message(size: size))
        defer { server.cancel() }
        let socket = try await Self.open(server)
        try await socket.send(data: Data([0x01]))

        let iterator = socket.makeAsyncIterator()
        if size <= 1 << 20 {
            guard case let .data(message) = try await iterator.next() else { return #expect(Bool(false)) }
            #expect(message.count == size)
        } else {
            let error = await #expect(throws: LiveKitError.self) { try await iterator.next() }
            #expect(error?.type == .network)
        }
    }

    /// The cookies stored for the URL go with the upgrade, as URLSession sent them; secure ones on a `wss` URL too.
    @Test func upgradeSendsStoredCookies() async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let url = try await server.url()
        let name = "lk-test-\(UUID().uuidString.prefix(8))"
        let cookies = try [
            #require(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: name, .value: "plain"])),
            #require(HTTPCookie(properties: [.domain: "cookie.test", .path: "/", .name: name, .value: "secure", .secure: "TRUE"])),
        ]
        cookies.forEach(HTTPCookieStorage.shared.setCookie)
        defer { cookies.forEach(HTTPCookieStorage.shared.deleteCookie) }

        let socket = try await LiveKit.WebSocket(url: url, headers: Self.headers, timeoutInterval: 10)
        defer { socket.close() }
        let lines = server.requestHeaders.copy().filter { $0.lowercased().hasPrefix("cookie:") }
        #expect(lines.count == 1)
        let cookie = try #require(lines.first)
        #expect(cookie.contains("\(name)=plain"))

        let secure = try LiveKit.WebSocket.upgradeHeaders(url: #require(URL(string: "wss://cookie.test/rtc")), headers: [])
        #expect(secure.contains { $0.name == "Cookie" && $0.value == "\(name)=secure" })
    }

    @Test func refusedConnectionFails() async throws {
        let port = try Self.unusedTCPPort()
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/rtc"))

        let events = SocketEvents()
        let error = await #expect(throws: LiveKitError.self) {
            try await LiveKit.WebSocket(url: url, headers: Self.headers, timeoutInterval: 10, onEvent: events.record)
        }
        #expect(events.teardowns.copy() == 1)
        #expect(events.closeStarts.copy() == 0)
        #expect(error?.type == .network)
        #expect((error?.internalError as? NSError)?.code == Int(ECONNREFUSED), "A reserved TCP port that has not listened must refuse the connection")
    }

    @Test func deadlineFailsAnUnansweredUpgrade() async throws {
        let server = try FakeWebSocketServer(.blackhole)
        defer { server.cancel() }
        let started = Date()
        let events = SocketEvents()
        let error = await #expect(throws: LiveKitError.self) {
            try await Self.open(server, timeoutInterval: 1, events: events)
        }
        #expect(events.teardowns.copy() == 1)
        #expect(events.closeStarts.copy() == 0)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(error?.type == .timedOut || error?.type == .network)
        #expect(error?.isRetryableForRegionFailover == true)
    }

    @Test func cancellationDuringConnect() async throws {
        let server = try FakeWebSocketServer(.blackhole)
        defer { server.cancel() }
        let url = try await server.url()
        let events = SocketEvents()
        let connect = Task { try await LiveKit.WebSocket(url: url, headers: Self.headers, timeoutInterval: 10, onEvent: events.record) }
        try await server.accepted.wait()
        let started = Date()
        connect.cancel()
        let error = await #expect(throws: LiveKitError.self) { try await connect.value }
        #expect(events.teardowns.copy() == 1)
        #expect(events.closeStarts.copy() == 0)
        #expect(error?.type == .cancelled)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// The status of a rejected upgrade comes from its own response: the upgrade is sent once.
    @Test func rejectedUpgradeCarriesTheStatus() async throws {
        let server = try FakeWebSocketServer(.reject(status: 401))
        defer { server.cancel() }
        let events = SocketEvents()
        let error = await #expect(throws: LiveKitError.self) { try await Self.open(server, events: events) }
        #expect(events.teardowns.copy() == 1)
        #expect(events.closeStarts.copy() == 0)
        #expect(error?.type == .network)
        #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == 401)
        #expect(server.acceptCount.copy() == 1)
    }

    // MARK: - Release

    /// What the Network.framework transport exists for: the URLSession one kept its session and task alive after
    /// `close()`, about 25 KB a connection, for the life of the process. Here the only transport object is the
    /// `NWConnection`, and it goes with the socket.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1173", "URLSession keeps every WebSocket session after close"),
          .bug("https://developer.apple.com/forums/thread/650733"),
          .bug("https://developer.apple.com/forums/thread/725039"))
    func closedSocketsAreReleased() async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        var sockets: [LiveKit.WebSocket] = []
        var transports: [WeakTransport] = []
        for _ in 0 ..< 20 {
            let socket = try await Self.open(server)
            sockets.append(socket)
            await transports.append(WeakTransport(socket: socket, connection: socket.connection))
        }
        for socket in sockets {
            socket.close()
        }
        sockets.removeAll()

        let deadline = Date().addingTimeInterval(10)
        while transports.contains(where: { !$0.isReleased }), Date() < deadline {
            await Task.yield()
        }
        for (index, transport) in transports.enumerated() {
            #expect(transport.socket == nil, "Socket \(index) is still retained")
            #expect(transport.connection == nil, "Connection \(index) is still retained")
        }
    }

    // MARK: - Peer closure

    /// Only our own close ends the stream; a close frame, a FIN or a reset fails it, so the signal client reconnects
    /// at once instead of waiting for its ping timeout.
    @Test(arguments: zip(
        [FakeWebSocketServer.Behavior.closeFrame, .fin, .reset],
        [Ending.closedByPeer(code: 1000), .networkError(posix: nil), .networkError(posix: ECONNRESET)],
    ))
    func peerClosure(behavior: FakeWebSocketServer.Behavior, ending: Ending) async throws {
        let server = try FakeWebSocketServer(behavior)
        defer { server.cancel() }
        let events = SocketEvents()
        let socket = try await Self.open(server, events: events)
        try await socket.send(data: Data([0x01]))

        switch ending {
        case let .closedByPeer(code):
            try await server.served.wait()
            let error = await #expect(throws: LiveKitError.self) { try await Self.messageCount(of: socket) }
            #expect(error?.type == .network)
            #expect((error?.internalError as? WebSocketClosedByPeer)?.code == code)
        case let .networkError(posix):
            let error = await #expect(throws: LiveKitError.self) { try await Self.messageCount(of: socket) }
            #expect(error?.type == .network)
            if let posix {
                #expect((error?.internalError as? NSError)?.code == Int(posix))
            }
        }

        // The server drops its side after the sequence ended: the late state change lands on a socket whose
        // opening is long settled, and must neither crash nor resurface.
        try await server.served.wait()
        #expect(events.teardowns.copy() == 1)
        #expect(await socket.connection.stateUpdateHandler == nil)
        withExtendedLifetime(socket) {}
    }
}

private extension WebSocketLifecycleTests {
    static func unusedTCPPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let located = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        try #require(located == 0)
        return UInt16(bigEndian: address.sin_port)
    }

    static func open(_ server: FakeWebSocketServer, timeoutInterval: TimeInterval = 10,
                     events: SocketEvents? = nil) async throws -> LiveKit.WebSocket
    {
        try await LiveKit.WebSocket(url: server.url(), headers: headers, timeoutInterval: timeoutInterval,
                                    onEvent: events?.record)
    }

    static func messageCount(of socket: LiveKit.WebSocket) async throws -> Int {
        try await socket.reduce(0) { count, _ in count + 1 }
    }
}

private struct WeakTransport {
    weak var socket: LiveKit.WebSocket?
    weak var connection: NWConnection?

    var isReleased: Bool { socket == nil && connection == nil }
}

private struct SocketEvents: Sendable {
    let receiveRegistered = AsyncCompleter<Void>(label: "SocketEvents.receiveRegistered", defaultTimeout: 5)
    let closeDeadline = AsyncCompleter<Void>(label: "SocketEvents.closeDeadline", defaultTimeout: 5)
    let teardowns = StateSync(0)
    let closeStarts = StateSync(0)

    func record(_ event: LiveKit.WebSocket.Event) {
        switch event {
        case .receiveRegistered: receiveRegistered.resume(returning: ())
        case .closeDeadline: closeDeadline.resume(returning: ())
        case .teardown: teardowns.mutate { $0 += 1 }
        case .closeStarted: closeStarts.mutate { $0 += 1 }
        case .readAheadFull: break
        }
    }
}
