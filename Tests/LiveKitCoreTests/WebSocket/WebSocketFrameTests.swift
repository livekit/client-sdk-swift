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

/// The signalling WebSocket's frame codec, inbox and upgrade check, with no connection.
@Suite(TestLimits.unit)
struct WebSocketFrameTests {
    // MARK: - Encoding and parsing

    /// A client frame takes the shortest length encoding at each boundary, and unmasks to its payload.
    @Test(arguments: [0, 125, 126, 65535, 65536])
    func clientFrameRoundTrips(length: Int) {
        let payload = Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0) })
        let frame = [UInt8](WebSocketFrame.client(opcode: WebSocketFrame.binary, payload))
        #expect(frame.first == 0x82)
        #expect(frame[1] & 0x80 != 0)
        let size = switch frame[1] & 0x7F {
        case 126: 4
        case 127: 10
        default: 2
        }
        #expect(size == (length < 126 ? 2 : length <= 0xFFFF ? 4 : 10))
        let declared = size == 2 ? Int(frame[1] & 0x7F) : frame[2 ..< size].reduce(0) { $0 << 8 | Int($1) }
        #expect(declared == length)
        let mask = Array(frame[size ..< size + 4])
        #expect(Data(frame[(size + 4)...].enumerated().map { $1 ^ mask[$0 & 3] }) == payload)
    }

    /// A frame split across two reads at any byte parses to the same message.
    @Test func frameSplitAtEveryPosition() {
        let payload = Data((0 ..< 260).map { UInt8(truncatingIfNeeded: $0) })
        let frame = FakeWebSocketServer.frame(0x2, payload)
        for split in 0 ... frame.count {
            var parser = Self.parser()
            parser.append(frame.prefix(split))
            let early = parser.next()
            parser.append(frame.dropFirst(split))
            guard case let .message(.data(data))? = early ?? parser.next() else {
                Issue.record("Split at \(split): no message")
                continue
            }
            #expect(data == payload, "Split at \(split)")
        }
    }

    /// The parser drops the frames it handed out once more bytes come, so a long session holds no history.
    @Test func parserHoldsNoHistory() {
        var parser = Self.parser()
        let frame = FakeWebSocketServer.frame(0x2, Data([0x01]))
        for _ in 0 ..< 1000 {
            parser.append(frame)
            #expect(parser.next() != nil)
        }
        #expect(parser.retainedBytes == frame.count)
    }

    /// A declared length over the limit fails at once, before any payload is held, with close code 1009; a 64-bit length
    /// with its most significant bit set breaks the protocol (RFC 6455 §5.2), with 1002.
    @Test(arguments: [(UInt64(WebSocket.maximumMessageSize) + 1, 1009), (UInt64.max, 1002)] as [(UInt64, UInt16)])
    func declaredLengthOverTheLimit(length: UInt64, expected: UInt16) {
        let item = Self.parse([0x82, 127] + (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        guard case let .failure(error, closeCode)? = item else { return #expect(Bool(false), "No failure") }
        #expect((error.internalError as NSError?)?.code == Int(expected == 1009 ? EMSGSIZE : EPROTO))
        #expect(closeCode == expected)
    }

    /// A length must take its shortest form (RFC 6455 §5.2): the 16-bit form for 126 through 65535 only, the 64-bit form
    /// from 65536. Each side of both boundaries, with no payload yet: the header alone decides.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"),
          arguments: [(126, 125), (126, 126), (127, 0xFFFF), (127, 0x10000)] as [(UInt8, UInt64)])
    func nonminimalLengthBreaksTheProtocol(marker: UInt8, length: UInt64) {
        let bytes = marker == 126 ? 2 : 8
        let fails = length < (marker == 126 ? 126 : 0x10000)
        let item = Self.parse([0x82, marker] + (0 ..< bytes).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        if fails {
            guard case let .failure(_, closeCode)? = item else { return #expect(Bool(false), "No failure") }
            #expect(closeCode == 1002)
        } else {
            #expect(item == nil)
        }
    }

    /// A length that is not in its shortest form fails once its header is whole, however the header is split, and on a
    /// continuation inside a fragmented message too; nothing comes out before, and nothing after.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"),
          arguments: [[126, 0, 125], [127, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]] as [[UInt8]])
    func splitNonminimalLengthBreaksTheProtocol(length: [UInt8]) {
        let unfinished = FakeWebSocketServer.frame(0x2, Data([0x61]), final: false)
        for (opener, header) in [(Data(), [0x82] + length), (unfinished, [0x80] + length)] {
            for split in 1 ..< header.count {
                var parser = Self.parser()
                parser.append(opener)
                parser.append(Data(header.prefix(split)))
                #expect(parser.next() == nil, "Split at \(split)")
                parser.append(Data(header.dropFirst(split)))
                guard case let .failure(_, closeCode)? = parser.next() else {
                    Issue.record("Split at \(split): no failure")
                    continue
                }
                #expect(closeCode == 1002)
                #expect(parser.next() == nil)
            }
        }
    }

    /// What the header alone breaks fails before its payload arrives: an unknown opcode, a continuation without a
    /// message, and a new message inside a fragmented one, each declaring 4 KB that never comes.
    @Test(arguments: [[0x83, 0x7E, 0x10, 0x00], [0x80, 0x7E, 0x10, 0x00], [0x02, 0x01, 0x00, 0x82, 0x7E, 0x10, 0x00]] as [[UInt8]])
    func headerFailsBeforeItsPayload(bytes: [UInt8]) {
        guard case let .failure(_, closeCode)? = Self.parse(bytes) else { return #expect(Bool(false), "No failure") }
        #expect(closeCode == 1002)
    }

    // MARK: - Close codes (RFC 6455 §7.4)

    @Test(arguments: [0, 999, 1004, 1005, 1006, 1015, 1016, 2999, 5000, 65535] as [UInt16])
    func forbiddenCloseCodeBreaksTheProtocol(code: UInt16) {
        guard case let .failure(error, closeCode)? = Self.parse(FakeWebSocketServer.close(code)) else {
            return #expect(Bool(false), "Close code \(code) accepted")
        }
        #expect(error.message?.hasPrefix("WebSocket protocol violation") == true)
        #expect(closeCode == 1002)
    }

    @Test(arguments: [1000, 1001, 1003, 1007, 1011, 1012, 1014, 3000, 4000, 4999] as [UInt16])
    func validCloseCodeCloses(code: UInt16) {
        guard case let .close(received)? = Self.parse(FakeWebSocketServer.close(code, reason: "bye")) else {
            return #expect(Bool(false), "Close code \(code) refused")
        }
        #expect(received == code)
    }

    /// A close frame with no code stands for 1005, which only a frame without a code can mean.
    @Test func emptyCloseIs1005() {
        guard case let .close(code)? = Self.parse([0x88, 0x00]) else { return #expect(Bool(false), "No close") }
        #expect(code == 1005)
    }

    // MARK: - Text (RFC 6455 §8.1)

    /// Text that is not UTF-8, whole or in fragments, ends the stream with close code 1007: nothing after it comes out.
    @Test(arguments: [[0x81, 0x01, 0xFF, 0x82, 0x01, 0x61], [0x01, 0x01, 0xE2, 0x80, 0x01, 0x41, 0x82, 0x01, 0x61]] as [[UInt8]])
    func invalidTextEndsTheStream(bytes: [UInt8]) {
        var parser = Self.parser()
        parser.append(Data(bytes))
        guard case let .failure(_, closeCode)? = parser.next() else { return #expect(Bool(false), "No failure") }
        #expect(closeCode == 1007)
        #expect(parser.next() == nil)
    }

    /// A character split across fragments joins into valid text.
    @Test func textSplitAcrossFragments() {
        guard case let .message(.string(text))? = Self.parse([0x01, 0x01, 0xE2, 0x80, 0x02, 0x82, 0xAC]) else {
            return #expect(Bool(false), "No text")
        }
        #expect(text == "€")
    }

    // MARK: - Inbox

    /// A reader that keeps a backlog, reading one message as one more arrives, holds no history: the frames and bytes
    /// it holds stay within twice the backlog.
    @Test func inboxHoldsNoHistory() {
        let size = 4096
        let message = FakeWebSocketServer.frame(0x2, Data(count: size))
        var inbox = WebSocket.Inbox()
        _ = inbox.ingest(Data((0 ..< WebSocket.readAhead).flatMap { _ in message }), isComplete: false, error: nil)
        for _ in 0 ..< 1000 {
            guard case .message? = inbox.take() else { return #expect(Bool(false), "No message") }
            let granted = inbox.startReceive()
            #expect(granted)
            inbox.receiving = false
            _ = inbox.ingest(message, isComplete: false, error: nil)
        }
        #expect(inbox.unread == WebSocket.readAhead)
        #expect(inbox.retainedFrames <= 2 * WebSocket.readAhead + 1)
        #expect(inbox.retainedBytes <= (2 * WebSocket.readAhead + 1) * size)
    }

    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func largePlainMessageAcrossReads() throws {
        let payload = Data((0 ..< WebSocket.maximumMessageSize).map { UInt8(truncatingIfNeeded: $0) })
        let wire = FakeWebSocketServer.frame(0x2, payload)
        var inbox = WebSocket.Inbox()
        let chunkSize = 1 << 16
        for offset in stride(from: 0, to: wire.count, by: chunkSize) {
            let chunk = wire.subdata(in: offset ..< min(offset + chunkSize, wire.count))
            let granted = inbox.startReceive()
            #expect(granted)
            inbox.receiving = false
            let reply = inbox.ingest(chunk, isComplete: false, error: nil)
            #expect(!reply.failed)
            #expect(reply.closeCode == nil)
            #expect(inbox.unread == (offset + chunk.count == wire.count ? 1 : 0))
        }
        let next = inbox.take()
        let frame = try #require(next)
        guard case let .message(.data(delivered)) = frame else {
            Issue.record("No data message")
            return
        }
        #expect(delivered == payload)
        #expect(inbox.take() == nil)
    }

    // MARK: - Upgrade response (RFC 6455 §4.1)

    /// The key and accept value of RFC 6455 §1.3.
    private static let key = "dGhlIHNhbXBsZSBub25jZQ=="
    private static let accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    /// Mixed case, a token list in `Connection`, and an interim head before the 101: the frames behind it are kept.
    @Test(arguments: [
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}",
        "HTTP/1.1 101 OK\r\nupgrade: WebSocket\r\nCONNECTION: keep-alive, UPGRADE\r\nsec-websocket-accept:{accept}",
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}",
    ])
    func upgradeOpens(head: String) {
        guard case let .opened(rest) = WebSocket.upgradeOutcome(Self.response(head) + Data([0x82, 0x00]), key: Self.key) else {
            return #expect(Bool(false), "Did not open")
        }
        #expect(rest.rest == Data([0x82, 0x00]))
    }

    @Test(arguments: [
        "XYZ 101 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}",
        "HTTP/2 401 Unauthorized",
        "HTTP/1.0 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}",
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: {accept}",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: close\r\nSec-WebSocket-Accept: {accept}",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Accept: {accept}",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: chat",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Extensions: unknown-extension",
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\nno colon",
    ])
    func upgradeFails(head: String) {
        guard case let .failed(error) = WebSocket.upgradeOutcome(Self.response(head), key: Self.key) else {
            return #expect(Bool(false), "Opened")
        }
        #expect((error.internalError as? URLError)?.code == .badServerResponse)
    }

    /// A rejection keeps its status in any HTTP/1.x, as the status line of HTTP/1.0 servers and proxies has it.
    @Test(arguments: [("HTTP/1.0 401 Unauthorized", 401), ("HTTP/1.0 503 Service Unavailable", 503), ("HTTP/1.1 401 Unauthorized", 401)])
    func rejectionKeepsItsStatus(head: String, status: Int) {
        guard case let .failed(error) = WebSocket.upgradeOutcome(Self.response(head + "\r\nContent-Length: 0"), key: Self.key) else {
            return #expect(Bool(false), "No failure")
        }
        #expect((error.internalError as? WebSocketUpgradeFailure)?.statusCode == status)
    }

    /// An interim head is skipped, and the final status reaches the caller.
    @Test func interimHeadThenRejection() {
        let head = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 401 Unauthorized\r\nContent-Length: 0"
        guard case let .failed(error) = WebSocket.upgradeOutcome(Self.response(head), key: Self.key) else {
            return #expect(Bool(false), "No failure")
        }
        #expect((error.internalError as? WebSocketUpgradeFailure)?.statusCode == 401)
    }

    /// Until the final head is whole, the upgrade waits for more bytes.
    @Test(arguments: ["HTTP/1.1 101 Switching", "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 101 Switching Protocols\r\n"])
    func incompleteHeadWaits(read: String) {
        guard case .incomplete = WebSocket.upgradeOutcome(Data(read.utf8), key: Self.key) else {
            return #expect(Bool(false), "Settled early")
        }
    }
}

private extension WebSocketFrameTests {
    static func parser() -> WebSocketFrame.Parser {
        WebSocketFrame.Parser(maximumMessageSize: WebSocket.maximumMessageSize)
    }

    static func parse(_ bytes: [UInt8]) -> WebSocketFrame.Item? {
        parse(Data(bytes))
    }

    static func parse(_ bytes: Data) -> WebSocketFrame.Item? {
        var parser = parser()
        parser.append(bytes)
        return parser.next()
    }

    static func response(_ head: String) -> Data {
        Data((head.replacingOccurrences(of: "{accept}", with: accept) + "\r\n\r\n").utf8)
    }
}

extension WebSocketFrameTests {
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func continuationOverTheMessageLimitFails() {
        var parser = Self.parser()
        parser.append(FakeWebSocketServer.frame(0x2, Data(repeating: 7, count: WebSocket.maximumMessageSize), final: false))
        #expect(parser.next() == nil)
        parser.append(FakeWebSocketServer.frame(0x0, Data([7])))
        guard case let .failure(error, closeCode)? = parser.next() else {
            Issue.record("No failure for the continuation")
            return
        }
        #expect(closeCode == 1009)
        #expect((error.internalError as NSError?)?.code == Int(EMSGSIZE))
        #expect(parser.next() == nil)
    }

    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"), arguments: [1, 126, 65536])
    func splitHeaderAtEveryByte(length: Int) {
        let payload = Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0) })
        let wire = FakeWebSocketServer.frame(0x2, payload)
        let headerSize = length < 126 ? 2 : length <= 0xFFFF ? 4 : 10
        for split in 1 ..< headerSize {
            var parser = Self.parser()
            parser.append(wire.prefix(split))
            #expect(parser.next() == nil)
            parser.append(wire.dropFirst(split))
            guard case let .message(.data(delivered))? = parser.next() else {
                Issue.record("No message at header split \(split)")
                continue
            }
            #expect(delivered == payload)
            #expect(parser.next() == nil)
        }
    }

    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func splitControlFrameAtEveryByte() {
        let payload = Data((0 ..< 125).map { UInt8($0) })
        let wire = FakeWebSocketServer.frame(0x9, payload)
        for split in 1 ..< wire.count {
            var parser = Self.parser()
            parser.append(wire.prefix(split))
            #expect(parser.next() == nil)
            parser.append(wire.dropFirst(split))
            guard case let .ping(delivered)? = parser.next() else {
                Issue.record("No ping at split \(split)")
                continue
            }
            #expect(delivered == payload)
            #expect(parser.next() == nil)
        }
    }
}

extension WebSocketFrame.Parser {
    /// The next item, or nil until more bytes arrive.
    mutating func next() -> WebSocketFrame.Item? {
        let input = input
        return input.withUnsafeBytes { next(in: $0) }
    }
}
