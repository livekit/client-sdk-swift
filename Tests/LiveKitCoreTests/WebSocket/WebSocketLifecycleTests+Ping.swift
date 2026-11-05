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
