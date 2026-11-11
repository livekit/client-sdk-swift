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

extension WebSocketLifecycleTests {
    /// A flood of pings, which never count as unread, gets a pong for the latest ping of a read (RFC 6455 §5.5.3),
    /// not one each.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func pingFloodIsAnsweredWithTheLatest() async throws {
        let pings = 200
        let flood = (0 ..< pings).reduce(into: Data()) { bytes, index in
            bytes += FakeWebSocketServer.frame(0x9, Data([UInt8(index >> 8), UInt8(index & 0xFF)]))
        }
        let server = try FakeWebSocketServer(.frames(flood + FakeWebSocketServer.close(1000)))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))

        let (_, error) = await Self.messages(of: socket)
        #expect(Self.closeCode(of: error) == 1000)
        try await server.served.wait()
        let pongs = server.frames.copy().filter { $0.opcode == 0xA }
        #expect(!pongs.isEmpty)
        #expect(pongs.count < pings / 10)
        let indices = pongs.map { Int($0.payload.first ?? 0) << 8 | Int($0.payload.last ?? 0) }
        #expect(indices == indices.sorted())
    }
}

extension WebSocketLifecycleTests {
    /// While a pong waits behind writes that TCP holds up, the pings of later reads leave only the latest to answer, and
    /// it goes once the first pong is out (RFC 6455 §5.5.3).
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191#discussion_r4476453195"))
    func pingsOfLaterReadsWaitForThePongInFlight() async throws {
        let frames = try await Self.withWritesHeldUp { server, socket, heldUp in
            for index: UInt8 in 0 ..< 3 {
                try await Self.ping(index, from: server, to: socket)
            }
            #expect(heldUp())
            server.readOn()
            while server.frames.copy().count(where: { $0.opcode == 0xA }) < 2 {
                try Task.checkCancellation()
                await Task.yield()
            }
            socket.close()
        }
        #expect(frames.filter { $0.opcode == 0xA }.map(\.payload) == [Data([0]), Data([2])])
    }

    /// A pong that waits when our close starts never goes: the close frame is the last frame.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191#discussion_r4476453195"))
    func noPongFollowsOurClose() async throws {
        let frames = try await Self.withWritesHeldUp { server, socket, heldUp in
            for index: UInt8 in 0 ..< 2 {
                try await Self.ping(index, from: server, to: socket)
            }
            #expect(heldUp())
            socket.close()
            server.readOn()
        }
        let control = frames.filter { $0.opcode != 0x2 }
        #expect(control.map(\.opcode) == [0xA, 0x8])
        #expect(control.first?.payload == Data([0]))
    }
}

private extension WebSocketLifecycleTests {
    /// Runs `body` on a socket whose writes TCP holds up: the server reads nothing until ``FakeWebSocketServer/readOn()``,
    /// and 15 MB of messages wait to go out, more than the loopback buffers take. `heldUp` tells whether some still
    /// wait. Returns the client's frames once the client dropped TCP.
    static func withWritesHeldUp(_ body: (FakeWebSocketServer, LiveKit.WebSocket, _ heldUp: @escaping () -> Bool) async throws -> Void)
        async throws -> [FakeWebSocketServer.ClientFrame]
    {
        let server = try FakeWebSocketServer(.upgradeOnly)
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10, closeWait: 10)
        let messages = 250, started = StateSync(0), written = StateSync(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< messages {
                group.addTask {
                    started.mutate { $0 += 1 }
                    // A write that our close or teardown cuts off fails; the frames the server read tell the outcome.
                    guard await (try? socket.send(data: Data(count: 60000))) != nil else { return }
                    written.mutate { $0 += 1 }
                }
            }
            while started.copy() < messages {
                try Task.checkCancellation()
                await Task.yield()
            }
            try await body(server, socket) { written.copy() < messages }
            try await group.waitForAll()
        }
        _ = try await server.clientGone.wait()
        return server.frames.copy()
    }

    /// The server sends a ping and a message with its index; the message comes out once the client has read the ping,
    /// so each ping is a read of its own.
    static func ping(_ index: UInt8, from server: FakeWebSocketServer, to socket: LiveKit.WebSocket) async throws {
        let connection = try #require(server.connections.copy().first)
        connection.send(content: FakeWebSocketServer.frame(0x9, Data([index])) + FakeWebSocketServer.binary([Data([index])]),
                        completion: .contentProcessed { _ in })
        guard case let .data(data)? = try await socket.makeAsyncIterator().next() else {
            Issue.record("No message after ping \(index)")
            return
        }
        #expect(data == Data([index]))
    }
}

extension WebSocketFrameTests {
    /// The pings of one read leave one pong to send: the latest one's.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func pingsOfOneReadLeaveTheLatestToAnswer() {
        var inbox = WebSocket.Inbox()
        let pings = (0 ..< 1000).reduce(into: Data()) { $0 += FakeWebSocketServer.frame(0x9, Data([UInt8($1 >> 8), UInt8($1 & 0xFF)])) }
        let reply = inbox.ingest(pings, isComplete: false, error: nil)
        #expect(reply.pong == Data([0x03, 0xE7]))
        #expect(inbox.unread == 0)
    }
}
