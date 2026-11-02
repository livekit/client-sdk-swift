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

    /// An interim head (`100 Continue`) before the 101 is skipped, as URLSession did: the socket opens, and the frames
    /// behind the 101 come out.
    @Test func interimHeadBeforeTheUpgrade() async throws {
        let head = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: {accept}\r\n\r\n"
        let payloads = Self.payloads(count: 2)
        let server = try FakeWebSocketServer(.upgradeResponse(head: head, then: FakeWebSocketServer.binary(payloads) + FakeWebSocketServer.close(1000)))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)

        let (received, error) = await Self.messages(of: socket)
        #expect(received == payloads)
        #expect(Self.closeCode(of: error) == 1000)
        try await server.served.wait()
    }

    /// An interim head and the final one share the 16 KB budget: together they may take it all, and not a byte more.
    @Test(arguments: [(WebSocket.upgradeResponseLimit, true), (WebSocket.upgradeResponseLimit + 1, false)])
    func interimAndFinalHeadShareTheBudget(total: Int, opens: Bool) async throws {
        let final = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
        // An accept value is 28 characters, where the template has 8.
        let interim = "HTTP/1.1 100 Continue\r\nX-Padding: \r\n\r\n"
        let padding = total - (final.utf8.count + 20) - interim.utf8.count
        let head = interim.replacingOccurrences(of: "X-Padding: ", with: "X-Padding: " + String(repeating: "a", count: padding)) + final
        let server = try FakeWebSocketServer(.upgradeResponse(head: head))
        defer { server.cancel() }
        if opens {
            let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
            socket.close()
            _ = try await server.served.wait()
        } else {
            let error = await #expect(throws: LiveKitError.self) {
                try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
            }
            #expect((error?.internalError as? URLError)?.code == .badServerResponse)
        }
    }

    /// A message over 1 MiB fails as soon as its header arrives: the client sends a masked close frame with 1009, and
    /// the error carries EMSGSIZE.
    @Test func oversizedMessageHeaderGetsClose1009() async throws {
        let length = UInt64(WebSocket.maximumMessageSize) + 1
        let header = Data([UInt8(0x82), 127] + (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        let server = try FakeWebSocketServer(.frames(header))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))
        try await server.served.wait()

        let (received, error) = await Self.messages(of: socket)
        #expect(received.isEmpty)
        #expect(((error as? LiveKitError)?.internalError as NSError?)?.code == Int(EMSGSIZE))
        let close = server.frames.read { $0.last }
        #expect(close?.opcode == 0x8)
        #expect(close?.masked == true)
        #expect(close?.payload == Data([0x03, 0xF1]))
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
        // Our close frame, with 1002 or, for a close reason that is not UTF-8, 1007.
        #expect(server.frames.read { $0.last?.opcode } == 0x8)
    }

    /// A close code that must not go on the wire breaks the protocol: the client answers with 1002, never with it.
    @Test(arguments: [999, 1005, 1006, 1015] as [UInt16])
    func forbiddenCloseCodeIsNotEchoed(code: UInt16) async throws {
        let server = try FakeWebSocketServer(.frames(FakeWebSocketServer.close(code)))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))
        try await server.served.wait()

        let (_, error) = await Self.messages(of: socket)
        #expect((error as? LiveKitError)?.message?.hasPrefix("WebSocket protocol violation") == true)
        #expect(Self.closeCode(of: error) == nil)
        #expect(server.frames.read { $0.last?.payload } == Data([0x03, 0xEA]))
    }

    /// Text that is not UTF-8, whole or in fragments, fails the connection after the messages before it: nothing after
    /// it is delivered, and the client's close frame carries 1007, as URLSession failed both reads.
    @Test(arguments: [[0x82, 0x01, 0x00, 0x81, 0x01, 0xFF, 0x82, 0x01, 0x61],
                      [0x82, 0x01, 0x00, 0x01, 0x01, 0xE2, 0x80, 0x01, 0x41, 0x82, 0x01, 0x61]] as [[UInt8]])
    func invalidTextFailsTheConnection(bytes: [UInt8]) async throws {
        let server = try FakeWebSocketServer(.frames(Data(bytes)))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))
        try await server.served.wait()

        let (received, error) = await Self.messages(of: socket)
        #expect(received == [Data([0x00])])
        #expect(((error as? LiveKitError)?.internalError as NSError?)?.code == Int(EPROTO))
        #expect(try await socket.makeAsyncIterator().next() == nil)
        #expect(server.frames.read { $0.last?.payload } == Data([0x03, 0xEF]))
    }

    /// The server's close frame arrives while a write is stuck behind TCP back-pressure, so the answer cannot be
    /// written, and our own close after it finds the socket closing already: the connection still goes at the deadline.
    @Test func peerCloseBehindAStalledWriteTearsDown() async throws {
        let server = try FakeWebSocketServer(.stalledReadThenClose)
        defer { server.cancel() }
        let teardown = AsyncCompleter<Void>(label: "teardown", defaultTimeout: 5)
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10, onEvent: { event in
            if case .teardown = event { teardown.resume(returning: ()) }
        })
        await withTaskGroup(of: Void.self) { group in
            // More than the loopback socket buffers hold, 4 MB each way: the write cannot finish on its own.
            group.addTask { _ = try? await socket.send(data: Data(count: 16 << 20)) }
            let (_, error) = await Self.messages(of: socket)
            #expect(Self.closeCode(of: error) == 1000)
            socket.close()
            let closed = DispatchTime.now().uptimeNanoseconds
            #expect(await (try? teardown.wait()) != nil)
            #expect(DispatchTime.now().uptimeNanoseconds - closed < 1_000_000_000)
            // Frees the write if it is still stuck.
            server.cancel()
        }
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
        let length: [UInt8] = [UInt8(127)] + (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: half >> ($0 * 8)) }
        let fragments = Data([0x02] + length) + Data(count: half) + Data([0x80] + length) + Data(count: half)
        let server = try FakeWebSocketServer(.frames(fragments))
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
        try await socket.send(data: Data([0x01]))

        let (received, error) = await Self.messages(of: socket)
        #expect(received.isEmpty)
        #expect(((error as? LiveKitError)?.internalError as NSError?)?.code == Int(EMSGSIZE))
    }

    /// A 101 response with the wrong accept key, without `Upgrade: websocket`, with a subprotocol that was not asked
    /// for, or with a head past the size limit, does not open the socket.
    @Test(arguments: [
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n",
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n"
            + "Sec-WebSocket-Protocol: chat\r\n\r\n",
        "HTTP/1.1 101 Switching Protocols\r\nX-Padding: \(String(repeating: "a", count: WebSocket.upgradeResponseLimit))\r\n\r\n",
    ])
    func badUpgradeResponseFails(response: String) async throws {
        let server = try FakeWebSocketServer(.upgradeResponse(head: response))
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
