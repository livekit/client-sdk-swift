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

enum WebSocketTestSupport {
    static func peerClosure(behavior: FakeWebSocketServer.Behavior, ending: Ending) async throws {
        let server = try FakeWebSocketServer(behavior)
        defer { server.cancel() }
        let events = SocketEvents()
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [("Authorization", "Bearer test")],
                                                 timeoutInterval: 10, onEvent: events.record)
        try await socket.send(data: Data([0x01]))

        switch ending {
        case let .closedByPeer(code):
            try await server.served.wait()
            let error = await #expect(throws: LiveKitError.self) { try await socket.reduce(0) { count, _ in count + 1 } }
            #expect(error?.type == .network)
            #expect((error?.internalError as? WebSocketClosedByPeer)?.code == code)
        case let .networkError(posix):
            let error = await #expect(throws: LiveKitError.self) { try await socket.reduce(0) { count, _ in count + 1 } }
            #expect(error?.type == .network)
            if let posix {
                #expect((error?.internalError as? NSError)?.code == Int(posix))
            }
        }

        // The server drops its side after the sequence ended: the late state change lands on a socket whose
        // opening is long settled, and must neither crash nor resurface.
        try await server.served.wait()
        try await events.teardown.wait()
        #expect(events.teardowns.copy() == 1)
        #expect(await socket.connection.stateUpdateHandler == nil)
        withExtendedLifetime(socket) {}
    }
}

struct SocketEvents: Sendable {
    let receiveRegistered = AsyncCompleter<Void>(label: "SocketEvents.receiveRegistered", defaultTimeout: 5)
    let closeDeadline = AsyncCompleter<Void>(label: "SocketEvents.closeDeadline", defaultTimeout: 5)
    let teardown = AsyncCompleter<Void>(label: "SocketEvents.teardown", defaultTimeout: 5)
    let teardowns = StateSync(0)
    let closeStarts = StateSync(0)

    func record(_ event: LiveKit.WebSocket.Event) {
        switch event {
        case .receiveRegistered: receiveRegistered.resume(returning: ())
        case .closeDeadline: closeDeadline.resume(returning: ())
        case .teardown:
            teardowns.mutate { $0 += 1 }
            teardown.resume(returning: ())
        case .closeStarted: closeStarts.mutate { $0 += 1 }
        case .readAheadFull: break
        }
    }
}
