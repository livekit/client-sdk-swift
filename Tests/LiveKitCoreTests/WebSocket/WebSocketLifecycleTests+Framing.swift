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
    /// Every message the server sent before its close frame, however late the reader starts, then the close frame's
    /// code. The reader starts once the client has answered the close frame. 250 messages is more than the 200 that the
    /// SFU can queue ahead of its close frame (livekit-server `pkg/routing/messagechannel.go`).
    @Test(arguments: [1, 5, 100, 250])
    func queuedMessagesBeforeCloseAreDelivered(count: Int) async throws {
        let payloads = Self.payloads(count: count)
        let server = try FakeWebSocketServer(.frames(FakeWebSocketServer.binary(payloads) + FakeWebSocketServer.close(1000)))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))
        try await server.served.wait()

        let (received, error) = await Self.messages(of: socket)
        #expect(received == payloads)
        #expect(Self.closeCode(of: error) == 1000)
    }

    /// A reader that stops after the first message, until the client has answered the server's close frame, still gets
    /// every message, then the close frame's code.
    @Test func slowReaderGetsEveryMessage() async throws {
        let payloads = Self.payloads(count: 5)
        let server = try FakeWebSocketServer(.frames(FakeWebSocketServer.binary(payloads) + FakeWebSocketServer.close(1000)))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))

        let (received, error) = await Self.messages(of: socket) { try await server.served.wait() }
        #expect(received == payloads)
        #expect(Self.closeCode(of: error) == 1000)
    }

    /// A 256 KB burst in one write: frames that span TCP reads lose nothing and keep their order.
    @Test func largeBurstBeforeClose() async throws {
        let payloads = Self.payloads(count: 4 * WebSocket.readAhead, size: 4096)
        let server = try FakeWebSocketServer(.frames(FakeWebSocketServer.binary(payloads) + FakeWebSocketServer.close(1000)))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))

        let (received, error) = await Self.messages(of: socket) { await Task.yield() }
        #expect(received == payloads)
        #expect(Self.closeCode(of: error) == 1000)
        try await server.served.wait()
    }

    /// With nobody reading, the socket stops once `readAhead` frames wait, short of the whole burst, and TCP holds the
    /// rest: reading then still gets every message and the close frame's code.
    @Test func readAheadIsBounded() async throws {
        let payloads = Self.payloads(count: 4 * WebSocket.readAhead, size: 4096)
        let server = try FakeWebSocketServer(.frames(FakeWebSocketServer.binary(payloads) + FakeWebSocketServer.close(1000)))
        defer { server.cancel() }
        let full = AsyncCompleter<Int>(label: "readAheadFull", defaultTimeout: 5)
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10, onEvent: { event in
            if case let .readAheadFull(unread) = event { full.resume(returning: unread) }
        })
        try await socket.send(data: Data([0x01]))

        let unread = try await full.wait()
        #expect(unread >= WebSocket.readAhead)
        #expect(unread < payloads.count)
        let (received, error) = await Self.messages(of: socket)
        #expect(received == payloads)
        #expect(Self.closeCode(of: error) == 1000)
    }

    /// The parser drops the frames it handed out once more bytes come, so a long session holds no history.
    @Test func parserHoldsNoHistory() {
        var parser = WebSocketFrame.Parser(maximumMessageSize: WebSocket.maximumMessageSize)
        let frame = FakeWebSocketServer.frame(0x2, Data([0x01]))
        for _ in 0 ..< 1000 {
            parser.append(frame)
            #expect(parser.next() != nil)
        }
        #expect(parser.retainedBytes == frame.count)
    }

    /// The bytes after the head of the upgrade response are the stream's first.
    @Test func framesInTheUpgradeResponseSegment() async throws {
        let payloads = Self.payloads(count: 3)
        let frames = FakeWebSocketServer.binary(payloads) + FakeWebSocketServer.close(1000)
        let server = try FakeWebSocketServer(.frames(frames, withUpgrade: true))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)

        let (received, error) = await Self.messages(of: socket)
        #expect(received == payloads)
        #expect(Self.closeCode(of: error) == 1000)
        try await server.served.wait()
    }

    /// A ping between the fragments of a message: the client answers it with a pong that carries its payload, and joins
    /// the fragments into one message.
    @Test func pingInsideFragmentedMessage() async throws {
        let frames = Data([0x02, 0x02, 0x61, 0x62, 0x89, 0x02, 0xAB, 0xCD, 0x80, 0x01, 0x63]) + FakeWebSocketServer.close(1000)
        let server = try FakeWebSocketServer(.frames(frames))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))
        try await server.served.wait()

        let (received, error) = await Self.messages(of: socket)
        #expect(received == [Data("abc".utf8)])
        #expect(Self.closeCode(of: error) == 1000)
        #expect(server.frames.read { $0.map(\.opcode) } == [0x2, 0xA, 0x8])
        #expect(server.frames.read { $0.first { $0.opcode == 0xA }?.payload } == Data([0xAB, 0xCD]))
    }

    /// The close frame's code, 1005 when it has none, fails the stream; the client's own close frame echoes it.
    @Test(arguments: [
        (Data([0x88, 0x00]), UInt16(1005), Data()),
        (FakeWebSocketServer.close(4000), UInt16(4000), Data([0x0F, 0xA0])),
        (FakeWebSocketServer.close(1001, reason: "going away"), UInt16(1001), Data([0x03, 0xE9])),
    ])
    func peerCloseCode(frame: Data, code: UInt16, echo: Data) async throws {
        let server = try FakeWebSocketServer(.frames(frame))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))
        try await server.served.wait()

        let (_, error) = await Self.messages(of: socket)
        #expect(Self.closeCode(of: error) == code)
        let answer = server.frames.read { $0.last }
        #expect(answer?.opcode == 0x8)
        #expect(answer?.payload == echo)
    }

    private static let violations: [[UInt8]] = [
        [0x82, 0x81, 0x01, 0x02, 0x03, 0x04, 0x00], // a masked server frame
        [0xC2, 0x01, 0x00], // a reserved bit
        [0x09, 0x00], // a fragmented ping
        [0x89, 0x7E, 0x00, 0x7E] + [UInt8](repeating: 0, count: 126), // a ping over 125 bytes
        [0x83, 0x00], // an unknown opcode
        [0x80, 0x01, 0x00], // a continuation without a message
        [0x02, 0x01, 0x00, 0x82, 0x01, 0x00], // a message inside a fragmented one
        [0x88, 0x01, 0x03], // a one-byte close frame
        [0x88, 0x04, 0x03, 0xE8, 0xFF, 0xFE], // a close reason that is not UTF-8
    ]

    @Test(arguments: violations)
    func protocolViolationFailsTheStream(bytes: [UInt8]) async throws {
        let server = try FakeWebSocketServer(.frames(Data(bytes)))
        defer { server.cancel() }
        let teardowns = StateSync(0)
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10, onEvent: { event in
            if case .teardown = event { teardowns.mutate { $0 += 1 } }
        })
        try await socket.send(data: Data([0x01]))

        let (received, error) = await Self.messages(of: socket)
        #expect(received.isEmpty)
        #expect((error as? LiveKitError)?.message?.hasPrefix("WebSocket protocol violation") == true)
        try await server.served.wait()
        #expect(teardowns.copy() == 1)
    }

    /// The stream ends inside a frame: the sequence fails as on a FIN between frames.
    @Test func endOfStreamInsideAFrameFails() async throws {
        let server = try FakeWebSocketServer(.frames(Data([0x82, 0x05, 0x00])))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))

        let (_, error) = await Self.messages(of: socket)
        #expect(((error as? LiveKitError)?.internalError as? URLError)?.code == .networkConnectionLost)
    }

    /// The 1 MiB limit counts every fragment of a message.
    @Test func fragmentsOverTheMessageLimitFail() async throws {
        let half = 600_000
        let length: [UInt8] = [127] + (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: half >> ($0 * 8)) }
        let fragments = Data([0x02] + length) + Data(count: half) + Data([0x80] + length) + Data(count: half)
        let server = try FakeWebSocketServer(.frames(fragments))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))

        let (received, error) = await Self.messages(of: socket)
        #expect(received.isEmpty)
        #expect(((error as? LiveKitError)?.internalError as NSError?)?.code == Int(EMSGSIZE))
    }

    /// A 101 response with the wrong accept key, or a head past the size limit, does not open the socket.
    @Test(arguments: [
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n",
        "HTTP/1.1 101 Switching Protocols\r\nX-Padding: \(String(repeating: "a", count: WebSocket.upgradeResponseLimit))\r\n\r\n",
    ])
    func badUpgradeResponseFails(response: String) async throws {
        let server = try FakeWebSocketServer(.upgradeResponse(Data(response.utf8)))
        defer { server.cancel() }
        let error = await #expect(throws: LiveKitError.self) {
            try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        }
        #expect((error?.internalError as? URLError)?.code == .badServerResponse)
    }
}

extension WebSocketLifecycleTests {
    /// Message `i` is `size` bytes of `i`.
    static func payloads(count: Int, size: Int = 1) -> [Data] {
        (0 ..< count).map { Data(repeating: UInt8(truncatingIfNeeded: $0), count: size) }
    }

    /// The code of the server close frame that `error` carries.
    static func closeCode(of error: Error?) -> UInt16? {
        ((error as? LiveKitError)?.internalError as? WebSocketClosedByPeer)?.code
    }

    /// The binary messages read until the sequence ends, and the error it ends with; `pause` runs after each message.
    static func messages(of socket: LiveKit.WebSocket,
                         pause: () async throws -> Void = {}) async -> (received: [Data], error: Error?)
    {
        var received: [Data] = []
        do {
            for try await message in socket {
                if case let .data(data) = message { received.append(data) }
                try await pause()
            }
            return (received, nil)
        } catch {
            return (received, error)
        }
    }
}
