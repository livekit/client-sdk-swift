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
    /// A reset while the read-ahead is full, so that no read is in flight, still tears the connection down at once; the
    /// messages read ahead come out before the failure.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func peerResetWhileReadAheadIsFullTearsDown() async throws {
        let payloads = Self.payloads(count: 2 * WebSocket.readAhead, size: 1024)
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
        // No FIN after the frames: the reset is the first the client hears of the end.
        let server = try FakeWebSocketServer(.upgradeResponse(head: head, then: FakeWebSocketServer.binary(payloads)))
        defer { server.cancel() }
        let events = SocketEvents()
        let full = AsyncCompleter<Void>(label: "readAheadFull", defaultTimeout: 5)
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10, onEvent: { event in
            if case .readAheadFull = event { full.resume(returning: ()) }
            events.record(event)
        })
        try await full.wait()

        server.reset()
        #expect(try await events.teardown.wait() == .failure)
        #expect(await socket.connection.stateUpdateHandler == nil)
        let (received, error) = await Self.messages(of: socket)
        #expect(received.count >= WebSocket.readAhead)
        #expect(received == Array(payloads.prefix(received.count)))
        #expect((error as? LiveKitError)?.type == .network)
        #expect(events.teardowns.copy() == 1)
    }
}

extension FakeWebSocketServer {
    /// Resets every connection.
    func reset() {
        connections.read { $0.forEach { $0.forceCancel() } }
    }
}
