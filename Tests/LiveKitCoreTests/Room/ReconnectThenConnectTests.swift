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

    /// The mutation that admits a reconnect must also register it, or a `connect()` /
    /// `disconnect()` landing in between finds nothing to cancel and drain, and the unregistered
    /// reconnect later cleans up over the new session.
    @Test func reconnectIsRegisteredWhenAdmitted() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let unregisteredAdmissions = StateSync(0)
            let onDidMutate = room._state.onDidMutate
            room._state.onDidMutate = { state, oldState in
                onDidMutate?(state, oldState)
                guard oldState.isReconnectingWithMode == nil, state.isReconnectingWithMode != nil,
                      state.reconnectTask == nil else { return }
                unregisteredAdmissions.mutate { $0 += 1 }
            }
            defer { room._state.onDidMutate = onDidMutate }

            try await room.startReconnect(reason: .debug)

            #expect(room.connectionState == .connected)
            #expect(unregisteredAdmissions.copy() == 0)
        }
    }

    /// While `connect()` waits for a cancelled reconnect, the room still reads `.connected`; a
    /// reconnect requested then (a stale socket's failure, say) must not start behind its back.
    @Test func reconnectIsRefusedDuringHandoff() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let stale = HeldReconnect(in: room)

            let connect = Task { try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: freshRoomToken()) }
            try await stale.cancelled.wait()

            await #expect(throws: LiveKitError.self) {
                try await room.startReconnect(reason: .debug)
            }

            stale.release.resume(returning: ())
            try await connect.value
            #expect(room.connectionState == .connected)
            #expect(room._state.isHandingOff == false)
        }
    }

    /// A `connect()` cancelled during its handoff still ends it, and the room takes the next one.
    @Test func cancelledConnectEndsItsHandoff() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let stale = HeldReconnect(in: room)

            let connect = Task { try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: freshRoomToken()) }
            try await stale.cancelled.wait()
            connect.cancel()
            stale.release.resume(returning: ())

            await #expect(throws: (any Error).self) {
                try await connect.value
            }
            #expect(room._state.isHandingOff == false)

            try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: freshRoomToken())
            #expect(room.connectionState == .connected)
        }
    }

    /// A `connect()` requested while another one hands off runs after it, not over it.
    @Test func connectQueuedBehindAHandoffRunsAfterIt() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let stale = HeldReconnect(in: room)
            let secondRoomName = UUID().uuidString
            // A connect registers as it is requested; this one while the first holds the runner.
            let secondQueued = AsyncCompleter<Void>(label: "Second connect queued", defaultTimeout: 10)
            room._connectTasks.onDidMutate = { tasks, _ in
                if tasks.count == 2 { secondQueued.resume(returning: ()) }
            }
            defer { room._connectTasks.onDidMutate = nil }

            let first = Task { try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: freshRoomToken()) }
            try await stale.cancelled.wait()
            let second = Task {
                try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: freshRoomToken(secondRoomName))
            }
            try await secondQueued.wait()
            stale.release.resume(returning: ())

            try await first.value
            try await second.value
            #expect(room.connectionState == .connected)
            #expect(room.name == secondRoomName)
            #expect(room._state.isHandingOff == false)
        }
    }

    /// The server's leave for the old session arrives while `disconnect()` waits for a cancelled
    /// reconnect; an app reconnecting from `didDisconnectWithError` must keep that new session.
    @Test func connectFromDidDisconnectSurvivesTheDrain() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let app = try ReconnectOnDisconnect(url: TestEnvironment.liveKitServerUrl(), token: freshRoomToken())
            room.add(delegate: app)
            let stale = HeldReconnect(in: room)

            let disconnect = Task { await room.disconnect() }
            try await stale.cancelled.wait()

            await room.signalClient(room.signalClient, didReceiveLeave: .disconnect, reason: .clientInitiated, regions: nil)
            // Delegates run on one serial queue: once this returns, `didDisconnectWithError` has
            // been delivered if it was published.
            await room.delegates.notifyAsync { _ in }

            // If the room already reported the disconnect, the app's new session comes up first.
            if app.didStart {
                try await app.waitForConnect()
            }
            stale.release.resume(returning: ())
            await disconnect.value
            try await app.waitForConnect()

            #expect(room.connectionState == .connected, "connectionState: \(room.connectionState)")
            #expect(room._state.sid != nil)
            #expect(room._state.isHandingOff == false)
        }
    }

    /// `disconnect()` interrupts a `connect()` held in its handshake instead of queuing behind it.
    @Test func disconnectInterruptsAHeldConnect() async throws {
        let server = try await HeldSocketServer.start()
        defer { server.stop() }
        let room = Room()

        // The socket timeout only bounds how long a regression takes to fail; it is not the oracle.
        let connect = Task {
            try await room.connect(url: server.url.absoluteString,
                                   token: freshRoomToken(),
                                   connectOptions: ConnectOptions(socketConnectTimeoutInterval: 10))
        }
        try await server.waitForConnection()

        await room.disconnect()

        let error = await #expect(throws: LiveKitError.self) {
            try await connect.value
        }
        #expect(error?.type == .cancelled, "error: \(String(describing: error))")
        #expect(room.connectionState == .disconnected)
    }

    /// `disconnect()` interrupts the connects it finds registered, so a connect must be registered
    /// before it starts running.
    @Test func connectIsRegisteredBeforeItRuns() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let registeredWhenRunning = StateSync<Bool?>(nil)
            let stale = HeldReconnect(in: room) {
                registeredWhenRunning.mutate { $0 = !room._connectTasks.copy().isEmpty }
            }

            let connect = Task { try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: freshRoomToken()) }
            try await stale.cancelled.wait()
            stale.release.resume(returning: ())
            try await connect.value

            #expect(registeredWhenRunning.copy() == true)
        }
    }

    private func freshRoomToken(_ roomName: String = UUID().uuidString) throws -> String {
        try TestEnvironment.liveKitServerToken(for: roomName,
                                               identity: "identity-0",
                                               canPublish: true,
                                               canPublishData: true,
                                               canPublishSources: [],
                                               canSubscribe: true)
    }
}

/// A reconnect registered on `room` that, once cancelled, keeps unwinding until released — the
/// slowest a cancelled reconnect can be, held by the test instead of a socket.
private final class HeldReconnect: Sendable {
    let cancelled = AsyncCompleter<Void>(label: "Stale reconnect cancelled", defaultTimeout: 10)
    let release = AsyncCompleter<Void>(label: "Stale reconnect released", defaultTimeout: 30)

    /// `onCancel` runs on the task that cancels it — for a `connect()`, inside its handoff.
    init(in room: Room, onCancel: @escaping @Sendable () -> Void = {}) {
        let cancelled = cancelled
        let release = release
        let task = Task {
            await withTaskCancellationHandler {
                await Task.detached { try? await release.wait() }.value
            } onCancel: {
                onCancel()
                cancelled.resume(returning: ())
            }
        }
        room._state.mutate { $0.reconnectTask = task.cancellable() }
    }
}

/// Connects the room again from `room(_:didDisconnectWithError:)`, once.
private final class ReconnectOnDisconnect: RoomDelegate, @unchecked Sendable {
    private let url: String
    private let token: String
    private let _started = StateSync(false)
    private let _connected = AsyncCompleter<Void>(label: "Reconnected from didDisconnect", defaultTimeout: 30)

    var didStart: Bool { _started.copy() }

    init(url: String, token: String) {
        self.url = url
        self.token = token
    }

    func waitForConnect() async throws {
        try await _connected.wait()
    }

    func room(_ room: Room, didDisconnectWithError _: LiveKitError?) {
        let isFirst = _started.mutate { started in
            defer { started = true }
            return !started
        }
        guard isFirst else { return }
        Task.discarding { [url, token, _connected] in
            try await room.connect(url: url, token: token)
            _connected.resume(returning: ())
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
