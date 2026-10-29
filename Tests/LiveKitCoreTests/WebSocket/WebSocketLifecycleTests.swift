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
    /// A close frame delivered to a pending receive ends the stream. One that lands while no receive is pending is
    /// consumed by Network.framework's close handshake, and the next receive fails with ENOTCONN instead.
    case closed
    case networkError(posix: Int32?)

    var testDescription: String {
        switch self {
        case .closed: "closed"
        case let .networkError(posix): "network error\(posix.map { " POSIX \($0)" } ?? "")"
        }
    }
}

private enum Limits {
    /// As `TestLimits.e2e`, resolved at runtime for the iOS 13 floor; a minute is ample for loopback.
    static var unit: any SuiteTrait {
        if #available(iOS 16, macOS 13, tvOS 16, visionOS 1, *) {
            let limit: TimeLimitTrait = .timeLimit(.minutes(1))
            return limit
        }
        let none: Tag.List = .tags()
        return none
    }
}

/// The signalling socket's lifecycle against a server that is not a LiveKit server: how it opens, how it fails to,
/// and how its message sequence ends for each way a peer can go away.
@Suite(.tags(.networking), Limits.unit)
struct WebSocketLifecycleTests {
    private static let headers = [(name: "Authorization", value: "Bearer test")]
    /// How long `close()` waits for the server's answer, in nanoseconds.
    private static let closeLimit: UInt64 = 250_000_000

    private static func open(_ server: FakeWebSocketServer, timeoutInterval: TimeInterval = 10) async throws -> LiveKit.WebSocket {
        try await LiveKit.WebSocket(url: server.url(), headers: headers, timeoutInterval: timeoutInterval)
    }

    private static func messageCount(of socket: LiveKit.WebSocket) async throws -> Int {
        try await socket.reduce(0) { count, _ in count + 1 }
    }

    // MARK: - Opening

    @Test func ownCloseEndsTheSequence() async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let socket = try await Self.open(server)
        let reader = Task { try await Self.messageCount(of: socket) }
        await Task.yield()
        socket.close()
        #expect(try await reader.value == 0)
    }

    /// As URLSession's `cancel(with: .normalClosure)`: the server sees a normal disconnect, and then the client drops the
    /// connection, whichever way the socket closes.
    @Test(arguments: ClosePath.allCases)
    func closeSendsNormalClosure(path: ClosePath) async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        var socket: LiveKit.WebSocket? = try await Self.open(server)
        switch path {
        case .close:
            socket?.close()
        case .cancelledRead:
            let reading = try #require(socket)
            let reader = Task { try await Self.messageCount(of: reading) }
            reader.cancel()
            #expect(try await reader.value == 0)
        case .release:
            socket = nil
        }
        _ = try await server.clientGone.wait()
        let close = server.frames.read { $0.last }
        #expect(close?.opcode == 0x8)
        #expect(close?.payload == Data([0x03, 0xE8]))
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
        let answered = server.closeAnswered.copy() ?? .max
        #expect(gone > answered || gone >= start + Self.closeLimit)
    }

    /// With no answer the client drops the connection at the 250 ms limit, not before, and well within the server's 5 s
    /// wait.
    @Test func unansweredCloseEndsAtTheLimit() async throws {
        let server = try FakeWebSocketServer(.unansweredClose)
        defer { server.cancel() }
        let socket = try await Self.open(server)
        let start = DispatchTime.now().uptimeNanoseconds
        socket.close()
        let gone = try await server.clientGone.wait()
        #expect(gone >= start + Self.closeLimit)
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

        _ = try await LiveKit.WebSocket(url: url, headers: Self.headers, timeoutInterval: 10)
        #expect(server.requestHeaders.copy().contains("Cookie: \(name)=plain"))

        let secure = try LiveKit.WebSocket.upgradeHeaders(url: #require(URL(string: "wss://cookie.test/rtc")), headers: [])
        #expect(secure.contains { $0.name == "Cookie" && $0.value == "\(name)=secure" })
    }

    @Test func refusedConnectionFails() async throws {
        let server = try FakeWebSocketServer(.idle)
        defer { server.cancel() }
        let url = try await server.url()
        try await server.stop()

        let error = await #expect(throws: LiveKitError.self) {
            try await LiveKit.WebSocket(url: url, headers: Self.headers, timeoutInterval: 10)
        }
        #expect(error?.type == .network)
        #expect((error?.internalError as? NSError)?.code == Int(ECONNREFUSED))
    }

    @Test func deadlineFailsAnUnansweredUpgrade() async throws {
        let server = try FakeWebSocketServer(.blackhole)
        defer { server.cancel() }
        let started = Date()
        let error = await #expect(throws: LiveKitError.self) {
            try await Self.open(server, timeoutInterval: 1)
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(error?.type == .timedOut || error?.type == .network)
        #expect(error?.isRetryableForRegionFailover == true)
    }

    @Test func cancellationDuringConnect() async throws {
        let server = try FakeWebSocketServer(.blackhole)
        defer { server.cancel() }
        let url = try await server.url()
        let connect = Task { try await LiveKit.WebSocket(url: url, headers: Self.headers, timeoutInterval: 10) }
        try await server.accepted.wait()
        let started = Date()
        connect.cancel()
        let error = await #expect(throws: LiveKitError.self) { try await connect.value }
        #expect(error?.type == .cancelled)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func rejectedUpgradeCarriesTheStatus() async throws {
        let server = try FakeWebSocketServer(.reject(status: 401))
        defer { server.cancel() }
        let error = await #expect(throws: LiveKitError.self) { try await Self.open(server) }
        #expect(error?.type == .network)
        #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == 401)
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

    /// A close frame is the only end of stream; a FIN or a reset fails the sequence so the signal client reconnects
    /// at once instead of waiting for its ping timeout.
    @Test(arguments: zip(
        [FakeWebSocketServer.Behavior.closeFrame, .fin, .reset],
        [Ending.closed, .networkError(posix: nil), .networkError(posix: ECONNRESET)],
    ))
    func peerClosure(behavior: FakeWebSocketServer.Behavior, ending: Ending) async throws {
        let server = try FakeWebSocketServer(behavior)
        defer { server.cancel() }
        let socket = try await Self.open(server)
        try await socket.send(data: Data([0x01]))

        switch ending {
        case .closed:
            do {
                #expect(try await Self.messageCount(of: socket) == 0)
            } catch let error as LiveKitError {
                #expect(error.type == .network)
                #expect((error.internalError as? NSError)?.code == Int(ENOTCONN))
            }
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
        withExtendedLifetime(socket) {}
    }
}

private struct WeakTransport {
    weak var socket: LiveKit.WebSocket?
    weak var connection: NWConnection?

    var isReleased: Bool { socket == nil && connection == nil }
}
