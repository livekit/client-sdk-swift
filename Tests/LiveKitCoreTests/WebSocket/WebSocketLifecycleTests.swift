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

import CryptoKit
import Foundation
@testable import LiveKit
import Network
import Testing

/// A WebSocket server on a loopback port that answers the upgrade by hand and then misbehaves on purpose.
/// Raw TCP rather than Network.framework's own WebSocket listener, so it can send what that never would:
/// a bare FIN, a reset, an HTTP status, or nothing at all.
final class FakeWebSocketServer: Sendable {
    enum Behavior: Sendable {
        /// Upgrade, then stay quiet until the client closes.
        case idle
        /// Upgrade, then a close frame with code 1000, then drop the socket once the client answers it.
        case closeFrame
        /// Upgrade, then a TCP FIN with no close frame.
        case fin
        /// Upgrade, then a TCP reset.
        case reset
        /// Answer the upgrade with an HTTP status instead of 101.
        case reject(status: Int)
        /// Accept TCP and never answer the upgrade.
        case blackhole
    }

    let behavior: Behavior
    /// Resumed once the server has finished with a connection: sent its last bytes or dropped the socket.
    let served = AsyncCompleter<Void>(label: "FakeWebSocketServer.served", defaultTimeout: 5)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeWebSocketServer")
    private let ready = AsyncCompleter<UInt16>(label: "FakeWebSocketServer.ready", defaultTimeout: 5)
    private let stopped = AsyncCompleter<Void>(label: "FakeWebSocketServer.stopped", defaultTimeout: 5)
    private let connections = StateSync<[NWConnection]>([])

    init(_ behavior: Behavior) throws {
        self.behavior = behavior
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [ready, stopped, listener] state in
            switch state {
            case .ready: ready.resume(returning: listener.port?.rawValue ?? 0)
            case let .failed(error): ready.resume(throwing: error)
            case .cancelled: stopped.resume(returning: ())
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connections.mutate { $0.append(connection) }
            connection.start(queue: queue)
            if case .blackhole = behavior { return }
            readUpgrade(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }

    func url() async throws -> URL {
        let port = try await ready.wait()
        return try #require(URL(string: "ws://127.0.0.1:\(port)/rtc"))
    }

    /// Returns once the port refuses connections again.
    func stop() async throws {
        connections.mutate { $0.forEach { $0.cancel() }; $0.removeAll() }
        listener.cancel()
        try await stopped.wait()
    }

    private func readUpgrade(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] content, _, _, error in
            guard error == nil, let content else { return connection.cancel() }
            let request = buffered + content
            guard let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) else {
                return readUpgrade(connection, buffered: request)
            }
            let header = String(bytes: request[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let key = header.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
            answer(connection, key: key)
        }
    }

    private func answer(_ connection: NWConnection, key: String) {
        if case let .reject(status) = behavior {
            let response = "HTTP/1.1 \(status) Rejected\r\nContent-Length: 0\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [served] _ in
                connection.cancel()
                served.resume(returning: ())
            })
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [self] _ in
            switch behavior {
            case .idle, .blackhole, .reject:
                break
            case .closeFrame:
                connection.send(content: Data([0x88, 0x02, 0x03, 0xE8]), completion: .contentProcessed { [served] _ in
                    // The client's close reply, then the socket goes: the client sees a state change after its stream ended.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { _, _, _, _ in
                        connection.cancel()
                        served.resume(returning: ())
                    }
                })
            case .fin:
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [served] _ in
                    served.resume(returning: ())
                })
            case .reset:
                connection.forceCancel()
                served.resume(returning: ())
            }
        })
    }
}

/// How iteration over the socket ends.
enum Ending: Sendable, CustomTestStringConvertible {
    case endOfStream
    case networkError(posix: Int32?)

    var testDescription: String {
        switch self {
        case .endOfStream: "end of stream"
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

    private static func open(_ server: FakeWebSocketServer, timeoutInterval: TimeInterval = 10) async throws -> LiveKit.WebSocket {
        try await LiveKit.WebSocket(url: server.url(), headers: headers, timeoutInterval: timeoutInterval)
    }

    private static func messageCount(of socket: LiveKit.WebSocket) async throws -> Int {
        try await socket.reduce(0) { count, _ in count + 1 }
    }

    // MARK: - Opening

    @Test func ownCloseEndsTheSequence() async throws {
        let server = try FakeWebSocketServer(.idle)
        let socket = try await Self.open(server)
        let reader = Task { try await Self.messageCount(of: socket) }
        await Task.yield()
        socket.close()
        #expect(try await reader.value == 0)
        try await server.stop()
    }

    @Test func refusedConnectionFails() async throws {
        let server = try FakeWebSocketServer(.idle)
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
        let started = Date()
        let error = await #expect(throws: LiveKitError.self) {
            try await Self.open(server, timeoutInterval: 1)
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(error?.type == .timedOut || error?.type == .network)
        #expect(error?.isRetryableForRegionFailover == true)
        try await server.stop()
    }

    @Test func cancellationDuringConnect() async throws {
        let server = try FakeWebSocketServer(.blackhole)
        let url = try await server.url()
        let connect = Task { try await LiveKit.WebSocket(url: url, headers: Self.headers, timeoutInterval: 10) }
        await Task.yield()
        let started = Date()
        connect.cancel()
        let error = await #expect(throws: LiveKitError.self) { try await connect.value }
        #expect(error?.type == .cancelled)
        #expect(Date().timeIntervalSince(started) < 5)
        try await server.stop()
    }

    @Test func rejectedUpgradeCarriesTheStatus() async throws {
        let server = try FakeWebSocketServer(.reject(status: 401))
        let error = await #expect(throws: LiveKitError.self) { try await Self.open(server) }
        #expect(error?.type == .network)
        #expect((error?.internalError as? WebSocketUpgradeFailure)?.statusCode == 401)
        try await server.stop()
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
        try await server.stop()
    }

    // MARK: - Peer closure

    /// A close frame is the only end of stream; a FIN or a reset fails the sequence so the signal client reconnects
    /// at once instead of waiting for its ping timeout.
    @Test(arguments: zip(
        [FakeWebSocketServer.Behavior.closeFrame, .fin, .reset],
        [Ending.endOfStream, .networkError(posix: nil), .networkError(posix: ECONNRESET)],
    ))
    func peerClosure(behavior: FakeWebSocketServer.Behavior, ending: Ending) async throws {
        let server = try FakeWebSocketServer(behavior)
        let socket = try await Self.open(server)

        switch ending {
        case .endOfStream:
            #expect(try await Self.messageCount(of: socket) == 0)
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
        try await server.stop()
    }
}

private struct WeakTransport {
    weak var socket: LiveKit.WebSocket?
    weak var connection: NWConnection?

    var isReleased: Bool { socket == nil && connection == nil }
}
