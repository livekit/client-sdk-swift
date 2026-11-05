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

/// Compressed messages of 1 MiB each that inflate from about 1 KB on the wire: one TCP read carries dozens of them.
enum CompressedBacklog {
    static let count = 4 * WebSocket.readAhead

    static func payloads() -> [Data] {
        (0 ..< count).map { Data(repeating: UInt8(truncatingIfNeeded: $0), count: WebSocket.maximumMessageSize) }
    }

    /// The server frames of `payloads`, with one deflate context across them, as permessage-deflate sends by default.
    static func frames(_ payloads: [Data]) throws -> Data {
        let deflater = try WebSocketCompression.Codec(compressing: true, windowBits: 15, noContextTakeover: false)
        return try payloads.reduce(into: Data()) { $0 += try FakeWebSocketServer.frame(0x42, deflater.process($1, final: true)) }
    }
}

extension WebSocketFrameTests {
    /// One read that inflates past the read-ahead stops parsing at it: the bytes after stay compressed.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func compressedBatchStopsAtReadAhead() throws {
        let wire = try CompressedBacklog.frames(CompressedBacklog.payloads())
        #expect(wire.count < 1 << 18)
        var inbox = WebSocket.Inbox()
        inbox.parser = try WebSocketFrame.Parser(maximumMessageSize: WebSocket.maximumMessageSize,
                                                 inflater: WebSocketCompression.Codec(compressing: false, windowBits: 15, noContextTakeover: false))
        let reply = inbox.ingest(wire, isComplete: false, error: nil)
        #expect(!reply.failed)
        #expect(inbox.unread == WebSocket.readAhead)
        #expect(inbox.retainedBytes <= WebSocket.readAhead * WebSocket.maximumMessageSize)
        let granted = inbox.startReceive()
        #expect(!granted)
    }

    /// The end of the stream behind the bytes that the read-ahead left unparsed comes out after their messages.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func streamEndWaitsBehindUnparsedMessages() throws {
        let payloads = CompressedBacklog.payloads()
        var inbox = WebSocket.Inbox()
        inbox.parser = try WebSocketFrame.Parser(maximumMessageSize: WebSocket.maximumMessageSize,
                                                 inflater: WebSocketCompression.Codec(compressing: false, windowBits: 15, noContextTakeover: false))
        let reply = try inbox.ingest(CompressedBacklog.frames(payloads), isComplete: true, error: nil)
        #expect(reply.failed)
        var received: [Data] = []
        var frame = inbox.take()
        while case let .message(.data(data))? = frame {
            received.append(data)
            #expect(inbox.unread <= WebSocket.readAhead)
            _ = inbox.parse()
            frame = inbox.take()
        }
        #expect(received == payloads)
        guard case .failed? = frame else { return #expect(Bool(false), "No end of stream") }
        let granted = inbox.startReceive()
        #expect(!granted)
    }
}

extension WebSocketFrameTests {
    /// A read that waits gets a message from a read that the read-ahead stopped: the inbox parses on to refill, so no
    /// TCP read starts while compressed bytes wait in the parser.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func handingOutRefillsBeforeTheNextRead() async throws {
        let wire = try CompressedBacklog.frames(CompressedBacklog.payloads())
        let (handed, inbox) = try await Self.handOut(to: 1) { $0.ingest(wire, isComplete: false, error: nil) }
        #expect(handed.count == 1)
        #expect(inbox.unread == WebSocket.readAhead)
        var probe = inbox
        let granted = probe.startReceive()
        #expect(!granted)
    }

    /// More reads wait than the read-ahead holds, behind a whole burst and the end of the stream: every read gets its
    /// message, and the rest come out in order before the end.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func waitingReadsBeyondTheReadAheadAreServed() async throws {
        let payloads = CompressedBacklog.payloads()
        let wire = try CompressedBacklog.frames(payloads)
        let readers = 2 * WebSocket.readAhead
        var (handed, inbox) = try await Self.handOut(to: readers) { $0.ingest(wire, isComplete: true, error: nil) }
        var received = handed.compactMap { frame -> Data? in
            guard case let .message(.data(data)) = frame else { return nil }
            return data
        }
        #expect(received.count == readers)
        var frame = inbox.take()
        while case let .message(.data(data))? = frame {
            received.append(data)
            _ = inbox.parse()
            frame = inbox.take()
        }
        #expect(received == payloads)
        guard case .failed? = frame else { return #expect(Bool(false), "No end of stream") }
    }

    /// Registers `count` reads, applies `change` and hands out as the socket does; returns the frames handed out, in
    /// order, and the inbox. Reads left waiting end with `.closed`.
    private static func handOut(to count: Int, _ change: @escaping @Sendable (inout WebSocket.Inbox) -> WebSocket.Reply) async throws
        -> (handed: [WebSocket.Frame], inbox: WebSocket.Inbox)
    {
        let inbox = try StateSync(Self.compressedInbox())
        let handed = StateSync<[WebSocket.Frame]>([])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< count {
                group.addTask {
                    _ = await withCheckedContinuation { continuation in
                        inbox.mutateWithoutObservation { $0.readers.append(continuation) }
                    }
                }
            }
            while inbox.read({ $0.readers.count }) < count {
                await Task.yield()
            }
            let (frames, waiting) = inbox.mutateWithoutObservation { inbox in
                var reply = change(&inbox)
                let frames = inbox.handOut(into: &reply)
                defer { inbox.readers.removeAll() }
                return (frames, inbox.readers)
            }
            handed.mutate { $0 = frames.map(\.frame) }
            for (reader, frame) in frames {
                reader.resume(returning: frame)
            }
            for reader in waiting {
                reader.resume(returning: .closed)
            }
        }
        return (handed.copy(), inbox.copy())
    }

    private static func compressedInbox() throws -> WebSocket.Inbox {
        var inbox = WebSocket.Inbox()
        inbox.parser = try WebSocketFrame.Parser(maximumMessageSize: WebSocket.maximumMessageSize,
                                                 inflater: WebSocketCompression.Codec(compressing: false, windowBits: 15, noContextTakeover: false))
        return inbox
    }
}

extension WebSocketLifecycleTests {
    /// A burst that one read holds, and that inflates to 64 MiB: the socket stops at the read-ahead, then hands out
    /// every message in order and the close frame after them as they are read.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func compressedBurstIsBoundedByReadAhead() async throws {
        let payloads = CompressedBacklog.payloads()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
        let server = try FakeWebSocketServer(.upgradeResponse(head: head, then: CompressedBacklog.frames(payloads) + FakeWebSocketServer.close(1000)))
        defer { server.cancel() }
        let full = AsyncCompleter<Int>(label: "readAheadFull", defaultTimeout: 5)
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10, onEvent: { event in
            if case let .readAheadFull(unread) = event { full.resume(returning: unread) }
        })

        #expect(try await full.wait() == WebSocket.readAhead)
        let (received, error) = await Self.messages(of: socket)
        #expect(received.count == payloads.count)
        #expect(received == payloads)
        #expect(Self.closeCode(of: error) == 1000)
    }
}
