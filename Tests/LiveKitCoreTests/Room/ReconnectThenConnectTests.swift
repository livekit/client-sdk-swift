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

#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// A reconnect left running when the app moves the `Room` to a new session (e.g. the socket died
/// while suspended, and on foreground the app connects to a fresh room) must not tear down the
/// new connection when it unwinds.
@Suite(.serialized, .tags(.networking, .e2e), TestLimits.e2e)
struct ReconnectThenConnectTests {
    enum Handoff: CaseIterable, Sendable {
        case disconnectThenConnect
        case connectOnly
    }

    @Test(arguments: Handoff.allCases)
    func staleReconnectDoesNotTearDownNextSession(handoff: Handoff) async throws {
        let server = try await HeldSocketServer.start()
        defer { server.stop() }

        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            room._state.mutate {
                // A single full attempt, whose socket `server` holds open until released — the
                // old session's server not answering while the app moves on.
                $0.connectOptions = ConnectOptions(reconnectAttempts: 1, socketConnectTimeoutInterval: 120)
                $0.connectedUrl = server.url
            }

            // The same unstructured task the websocket / transport failure paths start.
            let reconnect = Task { try? await room.startReconnect(reason: .debug) }
            try await server.waitForConnection()

            if handoff == .disconnectThenConnect {
                await room.disconnect()
            }

            let token = try TestEnvironment.liveKitServerToken(for: UUID().uuidString,
                                                               identity: "identity-0",
                                                               canPublish: true,
                                                               canPublishData: true,
                                                               canPublishSources: [],
                                                               canSubscribe: true)
            try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token)

            // The new session is up; only now does the stale reconnect's socket fail.
            server.release()
            await reconnect.value

            #expect(room.connectionState == .connected, "connectionState: \(room.connectionState)")
            #expect(room._state.sid != nil)
            #expect(room._state.disconnectError == nil)
        }
    }
}

/// A TCP server that accepts a connection and never answers, so a WebSocket opened against it
/// waits in its handshake until ``release()``.
private final class HeldSocketServer: @unchecked Sendable {
    private let listener: NWListener
    /// `nil` once released: from then on every connection is refused, so a client retrying the
    /// handshake on a new connection fails too instead of being held again.
    private let _connections = StateSync<[NWConnection]?>([])
    private let accepted = AsyncCompleter<Void>(label: "Held socket accepted", defaultTimeout: 30)

    let url: URL

    private init(listener: NWListener, port: UInt16) throws {
        self.listener = listener
        url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
    }

    static func start() async throws -> HeldSocketServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = AsyncCompleter<UInt16>(label: "Held socket listener ready", defaultTimeout: 10)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.resume(returning: listener.port?.rawValue ?? 0)
            case let .failed(error): ready.resume(throwing: error)
            default: break
            }
        }
        listener.newConnectionHandler = { _ in }
        listener.start(queue: .global())
        let server = try await HeldSocketServer(listener: listener, port: ready.wait())
        listener.newConnectionHandler = { [weak server] connection in
            let isHeld = server?._connections.mutate { connections -> Bool in
                connections?.append(connection)
                return connections != nil
            } ?? false
            guard isHeld else { return connection.cancel() }
            connection.start(queue: .global())
            server?.accepted.resume(returning: ())
        }
        return server
    }

    /// Resolves once a client is connected and waiting on the handshake.
    func waitForConnection() async throws {
        try await accepted.wait()
    }

    /// Fails every held handshake, and refuses any later connection.
    func release() {
        let held = _connections.mutate { connections in
            defer { connections = nil }
            return connections ?? []
        }
        for connection in held {
            connection.cancel()
        }
    }

    func stop() {
        release()
        listener.cancel()
    }
}
