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

extension SignalClientTests {
    /// A delegate callback ahead of the leave can still be suspended before it registers its publication, as a dynacast
    /// codec publish is while it adds its transceiver. The leave fails the waiting publications first and this late one
    /// as well, so the leave callback behind it runs at once, not after the publish timeout. Once that callback cleaned
    /// the client up, as `Room` does, the next connection publishes again.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"), .tags(.networking),
          arguments: [Livekit_LeaveRequest_Action.disconnect, .resume, .reconnect])
    func leaveFailsAPublicationRegisteredBehindIt(action: Livekit_LeaveRequest_Action) async throws {
        let (server, url) = try await FakeWebSocketServer.started(.idle)
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
        defer { socket.close() }
        let fixture = try await LeaveFixture(socket: socket)
        let client = fixture.client

        let pending = Task { try await client.sendAddTrack(cid: "TR_pending", name: "camera", type: .video) { _ in } }
        try await fixture.requested.completer(for: "TR_pending").wait()

        let proceed = AsyncCompleter<Void>(label: "callback proceeds", defaultTimeout: 5)
        try await fixture.publishFromDelegate(cid: "TR_late") { try await proceed.wait() }

        let delivery = try fixture.deliverLeave(action, from: socket)
        // The pending publication fails once the leave reset the publications, before the callback registers its own.
        let pendingError = await #expect(throws: LiveKitError.self) { try await pending.value }
        #expect(pendingError?.type == .participantRemoved)
        proceed.resume(returning: ())
        await delivery.value
        #expect(fixture.delegate.events.copy() == [.latePublication(.participantRemoved), .leave])

        try await expectNextConnectionPublishes(client, url: url, requested: fixture.requested)
    }

    /// A delegate callback ahead of the leave can also hold the completer of its publication already, while it sends the
    /// request. The leave fails that completer for good, so the wait that follows the send fails at once with the
    /// leave's reason instead of after the publish timeout.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"), .tags(.networking),
          arguments: [Livekit_LeaveRequest_Action.disconnect, .resume, .reconnect])
    func leaveFailsAPublicationThatIsStillSending(action: Livekit_LeaveRequest_Action) async throws {
        let (server, url) = try await FakeWebSocketServer.started(.idle)
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
        defer { socket.close() }
        let release = AsyncCompleter<Void>(label: "addTrack send release", defaultTimeout: 5)
        let fixture = try await LeaveFixture(socket: socket, holding: "TR_sending", until: release)
        let client = fixture.client

        let pending = Task { try await client.sendAddTrack(cid: "TR_pending", name: "camera", type: .video) { _ in } }
        try await fixture.requested.completer(for: "TR_pending").wait()

        try await fixture.publishFromDelegate(cid: "TR_sending") {}
        // The request processor holds the send: the callback holds its completer and has not waited on it.
        try await fixture.requested.completer(for: "TR_sending").wait()

        let delivery = try fixture.deliverLeave(action, from: socket)
        // The pending publication fails once the leave reset the publications, the held completer with them.
        let pendingError = await #expect(throws: LiveKitError.self) { try await pending.value }
        #expect(pendingError?.type == .participantRemoved)
        release.resume(returning: ())
        try await fixture.requested.completer(for: "TR_sending released").wait()
        await delivery.value
        #expect(fixture.delegate.events.copy() == [.latePublication(.participantRemoved), .leave])
    }

    private func expectNextConnectionPublishes(_ client: SignalClient, url: URL, requested: CompleterMapActor<Void>) async throws {
        let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
        defer { socket.close() }
        await client._state.mutate {
            $0.socket = socket
            $0.connectionState = .connected
        }
        await client.resumeQueues()
        try await client.onWebSocketMessage(.data(Livekit_SignalResponse.with { $0.reconnect = .with { _ in } }.serializedData()), from: socket)
        async let published = client.sendAddTrack(cid: "TR_next", name: "camera", type: .video) { _ in }
        try await requested.completer(for: "TR_next").wait()
        try await client.onWebSocketMessage(.data(Livekit_SignalResponse.with { $0.trackPublished = .with {
            $0.cid = "TR_next"
            $0.track = .with { $0.sid = "TR_server" }
        } }.serializedData()), from: socket)
        #expect(try await published.sid == "TR_server")
        await client.cleanUp()
    }
}

/// A connected client whose request processor reports every add-track request, and can hold the send of one of them.
private struct LeaveFixture {
    let client: SignalClient
    let delegate: CleaningUpLeaveDelegate
    let requested = CompleterMapActor<Void>(label: "addTrack request", defaultTimeout: 5)

    init(socket: LiveKit.WebSocket, holding heldCid: String? = nil, until release: AsyncCompleter<Void>? = nil) async throws {
        let requested = requested
        client = try await SignalClient(testingResponse: .with { $0.refreshToken = "token" }, requestProcessor: { request in
            guard case let .addTrack(addTrack) = request.message else { return }
            await requested.resume(returning: (), for: addTrack.cid)
            guard addTrack.cid == heldCid, let release else { return }
            // Reported to the test, which waits on it: this runs in the delegate's detached task, outside the test.
            let released = await requested.completer(for: "\(addTrack.cid) released")
            do {
                try await release.wait()
                released.resume(returning: ())
            } catch {
                released.resume(throwing: error)
            }
        }, responseProcessed: {})
        delegate = CleaningUpLeaveDelegate(client: client)
        await client._delegate.set(delegate: delegate)
        await client._state.mutate {
            $0.socket = socket
            $0.connectionState = .connected
        }
        await client.resumeQueues()
    }

    /// Publishes from a callback that holds the serial delegate, once `before` returns, and records how that ended.
    /// Returns once the callback holds the delegate, so that a leave queues behind it.
    func publishFromDelegate(cid: String, before: @escaping @Sendable () async throws -> Void) async throws {
        let entered = AsyncCompleter<Void>(label: "callback entered", defaultTimeout: 5)
        let client = client
        let delegate = delegate
        await client._delegate.notifyDetached { _ in
            entered.resume(returning: ())
            do {
                try await before()
                _ = try await client.sendAddTrack(cid: cid, name: "camera", type: .video) { _ in }
                delegate.events.mutate { $0.append(.latePublication(nil)) }
            } catch {
                delegate.events.mutate { $0.append(.latePublication((error as? LiveKitError)?.type)) }
            }
        }
        try await entered.wait()
    }

    func deliverLeave(_ action: Livekit_LeaveRequest_Action, from socket: LiveKit.WebSocket) throws -> Task<Void, Never> {
        let leave = try Livekit_SignalResponse.with { $0.leave = .with {
            $0.action = action
            $0.reason = .participantRemoved
        } }.serializedData()
        let client = client
        return Task { await client.onWebSocketMessage(.data(leave), from: socket) }
    }
}

/// Cleans the client up on a leave, as `Room` does for every action it knows.
private final class CleaningUpLeaveDelegate: SignalClientTestDelegate {
    enum Event: Equatable { case latePublication(LiveKitErrorType?), leave }
    let client: SignalClient
    let events = StateSync<[Event]>([])

    init(client: SignalClient) {
        self.client = client
    }

    func signalClient(_: SignalClient, didReceiveLeave _: Livekit_LeaveRequest_Action, reason: Livekit_DisconnectReason, regions _: Livekit_RegionSettings?) async {
        events.mutate { $0.append(.leave) }
        await client.cleanUp(withError: LiveKitError.from(reason: reason))
    }
}
