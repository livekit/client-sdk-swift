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

extension WebSocketFrameTests {
    @Test(arguments: 8 ... 15)
    func compressionNegotiatesWindowsAndTakeover(bits: Int) throws {
        let parameters = try #require(try WebSocketCompression.negotiate([
            "permessage-deflate; server_max_window_bits=\"\(bits)\"; client_max_window_bits=\(bits); server_no_context_takeover; client_no_context_takeover",
        ]))
        #expect(parameters.serverWindowBits == bits)
        #expect(parameters.clientWindowBits == bits)
        #expect(parameters.serverNoContextTakeover)
        #expect(parameters.clientNoContextTakeover)
        let data = Data((0 ..< 8192).map { UInt8(truncatingIfNeeded: $0) })
        let deflater = try WebSocketCompression.Codec(compressing: true, windowBits: bits, noContextTakeover: true)
        let inflater = try WebSocketCompression.Codec(compressing: false, windowBits: bits, noContextTakeover: true)
        for _ in 0 ..< 2 {
            let compressed = try deflater.process(data, final: true)
            #expect(try inflater.process(compressed, final: true) == data)
        }
    }

    @Test(arguments: ["gzip", "permessage-deflate, permessage-deflate", "permessage-deflate; unknown", "permessage-deflate;",
                      "permessage-deflate; server_no_context_takeover=1", "permessage-deflate; client_max_window_bits",
                      "permessage-deflate; server_max_window_bits=7", "permessage-deflate; client_max_window_bits=16",
                      "permessage-deflate; client_max_window_bits=09", "permessage-deflate; server_max_window_bits=\"15",
                      "permessage-deflate; server_no_context_takeover; server_no_context_takeover"])
    func invalidCompressionParametersAreRejected(header: String) {
        #expect(throws: LiveKitError.self) { try WebSocketCompression.negotiate([header]) }
    }

    @Test func absentOrDuplicateCompressionExtensions() throws {
        #expect(try WebSocketCompression.negotiate([]) == nil)
        #expect(throws: LiveKitError.self) { try WebSocketCompression.negotiate(["permessage-deflate", "permessage-deflate"]) }
    }

    /// RFC 7692 §7.2.3.1, including fragmentation and an interleaved ping. RSV1 belongs only on the first fragment.
    @Test func fragmentedCompressedTextAndPing() throws {
        var parser = try Self.compressionParser()
        parser.append(Data([0x41, 3, 0xF2, 0x48, 0xCD, 0x89, 1, 42, 0x80, 4, 0xC9, 0xC9, 0x07, 0]))
        guard case let .ping(data)? = parser.next() else {
            Issue.record("Missing ping")
            return
        }
        #expect(data == Data([42]))
        guard case let .message(.string(text))? = parser.next() else {
            Issue.record("Missing text")
            return
        }
        #expect(text == "Hello")
        #expect(parser.next() == nil)
    }

    /// RFC 7692 §7.2.3.2: an intervening uncompressed message does not change compression history.
    @Test func inflaterKeepsContextAcrossMessages() throws {
        var parser = try Self.compressionParser()
        parser.append(FakeWebSocketServer.frame(0x42, Self.compressedHello)
            + FakeWebSocketServer.frame(0x2, Data([42]))
            + FakeWebSocketServer.frame(0x42, Data([0xF2, 0, 0x11, 0, 0])))
        #expect(try Self.binaryMessage(parser.next()) == Data("Hello".utf8))
        #expect(try Self.binaryMessage(parser.next()) == Data([42]))
        #expect(try Self.binaryMessage(parser.next()) == Data("Hello".utf8))
    }

    @Test func inflaterResetsOnlyAtMessageBoundaries() throws {
        var parser = try Self.compressionParser(noContextTakeover: true)
        parser.append(FakeWebSocketServer.frame(0x42, Self.compressedHello)
            + FakeWebSocketServer.frame(0x42, Self.compressedHello)
            + FakeWebSocketServer.frame(0x42, Data([0xF2, 0, 0x11, 0, 0])))
        #expect(try Self.binaryMessage(parser.next()) == Data("Hello".utf8))
        #expect(try Self.binaryMessage(parser.next()) == Data("Hello".utf8))
        #expect(Self.compressionCloseCode(parser.next()) == 1007)
    }

    /// RFC 7692 §7.2.3.4: BFINAL may precede the terminating empty block.
    @Test func compressedFinalBlockIsAccepted() throws {
        var parser = try Self.compressionParser()
        parser.append(FakeWebSocketServer.frame(0x42, Data([0xF3, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0, 0]))
            + FakeWebSocketServer.frame(0x42, Data([0xF2, 0, 0x11, 0, 0])))
        #expect(try Self.binaryMessage(parser.next()) == Data("Hello".utf8))
        #expect(try Self.binaryMessage(parser.next()) == Data("Hello".utf8))
    }

    @Test(arguments: [UInt8(0), 8, 9, 10])
    func compressedControlOrContinuationIsRejected(opcode: UInt8) throws {
        var parser = try Self.compressionParser()
        if opcode == 0 { parser.append(Data([0x02, 0])) }
        parser.append(FakeWebSocketServer.frame(0x40 | opcode, Data()))
        #expect(Self.compressionCloseCode(parser.next()) == 1002)
    }

    @Test func unnegotiatedOrInvalidCompressedDataFails() throws {
        var plain = WebSocketFrame.Parser(maximumMessageSize: WebSocket.maximumMessageSize)
        plain.append(FakeWebSocketServer.frame(0x42, Self.compressedHello))
        #expect(Self.compressionCloseCode(plain.next()) == 1002)
        var compressed = try Self.compressionParser()
        compressed.append(FakeWebSocketServer.frame(0x42, Data([0xFF])))
        #expect(Self.compressionCloseCode(compressed.next()) == 1007)
    }

    @Test(arguments: [Data(), Data([0xF2])])
    func incompleteDeflateBlockIsRejected(payload: Data) throws {
        var parser = try Self.compressionParser()
        parser.append(FakeWebSocketServer.frame(0x42, payload))
        #expect(Self.compressionCloseCode(parser.next()) == 1007)
    }

    @Test func compressedLengthHighBitIsRejected() throws {
        var parser = try Self.compressionParser()
        parser.append(Data([0xC2, 127, 0x80, 0, 0, 0, 0, 0, 0, 0]))
        #expect(Self.compressionCloseCode(parser.next()) == 1002)
    }

    @Test(arguments: [WebSocket.maximumMessageSize, WebSocket.maximumMessageSize + 1])
    func limitAppliesToInflatedMessage(size: Int) throws {
        let data = Data(repeating: 42, count: size)
        let deflater = try WebSocketCompression.Codec(compressing: true, windowBits: 15, noContextTakeover: false)
        let compressed = try deflater.process(data, final: true)
        #expect(compressed.count < WebSocket.maximumMessageSize)
        var parser = try Self.compressionParser()
        parser.append(FakeWebSocketServer.frame(0x42, compressed))
        if size == WebSocket.maximumMessageSize {
            #expect(try Self.binaryMessage(parser.next()) == data)
        } else {
            #expect(Self.compressionCloseCode(parser.next()) == 1009)
        }
    }

    @Test func inflationLimitStopsAnIncompleteFrame() throws {
        let deflater = try WebSocketCompression.Codec(compressing: true, windowBits: 15, noContextTakeover: false)
        let compressed = try deflater.process(Data(repeating: 42, count: WebSocket.maximumMessageSize), final: true)
        var parser = try Self.compressionParser(limit: 1024)
        let wire = FakeWebSocketServer.frame(0x42, compressed)
        parser.append(Data(wire.prefix(wire.count / 2)))
        #expect(Self.compressionCloseCode(parser.next()) == 1009)
    }

    /// Empty DEFLATE blocks can make the wire payload larger than the inflated limit. They must stream, not buffer.
    @Test func compressedWireSizeDoesNotReplaceInflatedLimit() throws {
        var payload = Data()
        for _ in 0 ..< (1 << 18) {
            payload.append(contentsOf: [0, 0, 0, 255, 255])
        }
        payload.append(0)
        #expect(payload.count > WebSocket.maximumMessageSize)
        let wire = Data([0xC2, 0x7F]) + Data((0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) }) + payload
        var parser = try Self.compressionParser()
        var result: Data?
        for offset in stride(from: 0, to: wire.count, by: 16384) {
            parser.append(Data(wire[offset ..< min(offset + 16384, wire.count)]))
            if let item = parser.next() { result = try Self.binaryMessage(item) }
            #expect(parser.retainedBytes <= 16394)
        }
        #expect(result == Data())
    }
}

private extension WebSocketFrameTests {
    static var compressedHello: Data { Data([0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0]) }

    static func compressionParser(noContextTakeover: Bool = false, limit: Int = WebSocket.maximumMessageSize) throws -> WebSocketFrame.Parser {
        try WebSocketFrame.Parser(maximumMessageSize: limit,
                                  inflater: WebSocketCompression.Codec(compressing: false, windowBits: 15, noContextTakeover: noContextTakeover))
    }

    static func binaryMessage(_ item: WebSocketFrame.Item?) throws -> Data {
        guard case let .message(.data(data))? = item else {
            Issue.record("Expected a binary message")
            throw WebSocketCompression.failure()
        }
        return data
    }

    static func compressionCloseCode(_ item: WebSocketFrame.Item?) -> UInt16? {
        guard case let .failure(_, code)? = item else { return nil }
        return code
    }
}
