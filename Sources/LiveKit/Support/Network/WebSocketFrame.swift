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

/// RFC 6455 frames: what the client writes, and what it reads off the server's byte stream.
enum WebSocketFrame {
    static let text: UInt8 = 0x1
    static let binary: UInt8 = 0x2
    static let close: UInt8 = 0x8
    static let ping: UInt8 = 0x9
    static let pong: UInt8 = 0xA

    /// A client frame, whole and masked with a fresh key, as RFC 6455 §5.3 requires.
    static func client(opcode: UInt8, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        switch payload.count {
        case ..<126:
            frame.append(0x80 | UInt8(payload.count))
        case ...0xFFFF:
            frame.append(contentsOf: [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) })
        }
        let mask = (0 ..< 4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for index in masked.indices {
            masked[index] ^= mask[index & 3]
        }
        frame.append(contentsOf: masked)
        return frame
    }

    /// A client close frame with `code`; with no code for 1005, which a frame must not carry.
    static func clientClose(_ code: UInt16) -> Data {
        client(opcode: close, code == 1005 ? Data() : Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }

    /// The codes that a close frame may carry (RFC 6455 §7.4): the ones defined for use, and the range for applications.
    /// 1005, 1006 and 1015 never go on the wire, 1004 and 1016 to 2999 are reserved, and nothing else is defined.
    static func isValidCloseCode(_ code: UInt16) -> Bool {
        switch code {
        case 1000 ... 1003, 1007 ... 1014, 3000 ... 4999: true
        default: false
        }
    }

    /// What a server frame, or the message its fragments make, means to the client.
    enum Item {
        case message(URLSessionWebSocketTask.Message)
        case ping(Data)
        case pong
        /// The server's close frame, with its code; 1005 when it has none.
        case close(UInt16)
        /// A frame that breaks the protocol, text that is not UTF-8, or a message over the size limit: the stream is
        /// over, and our close frame carries `closeCode`.
        case failure(LiveKitError, closeCode: UInt16)
    }

    /// Takes the server's bytes as they arrive and hands out whole frames in order. After a close frame or a failure it
    /// hands out nothing more.
    struct Parser {
        let maximumMessageSize: Int
        /// Bytes read from `start` on that do not make a whole frame yet; before `start`, frames already handed out.
        private var bytes: [UInt8] = []
        private var start = 0
        /// The fragments of a message so far.
        private var fragments: (text: Bool, data: Data)?
        private var over = false

        init(maximumMessageSize: Int) {
            self.maximumMessageSize = maximumMessageSize
        }

        /// The bytes held: what is not handed out yet, and at most the frames of the last read that were.
        var retainedBytes: Int { bytes.count }

        mutating func append(_ data: Data) {
            guard !over else { return }
            // Drops what was handed out before it grows: the buffer holds at most one unfinished message and a read.
            bytes.removeFirst(start)
            start = 0
            bytes.append(contentsOf: data)
        }

        /// The next item, or nil until more bytes arrive.
        mutating func next() -> Item? {
            while !over, let header = header() {
                if let failure = check(header) { return end(failure) }
                guard bytes.count - start >= header.size + header.length else { return nil }
                let payload = Data(bytes[(start + header.size) ..< (start + header.size + header.length)])
                start += header.size + header.length
                if let item = item(header, payload) { return item }
            }
            return nil
        }

        private struct Header {
            let fin: Bool
            let opcode: UInt8
            let flags: (reserved: Bool, masked: Bool)
            let length: Int
            let size: Int
        }

        /// The header at `start`, once it is whole.
        private func header() -> Header? {
            let available = bytes.count - start
            guard available >= 2 else { return nil }
            let first = bytes[start], second = bytes[start + 1]
            var size = 2, length = Int(second & 0x7F)
            if length == 126 {
                size = 4
                guard available >= size else { return nil }
                length = bytes[(start + 2) ..< (start + 4)].reduce(0) { $0 << 8 | Int($1) }
            } else if length == 127 {
                size = 10
                guard available >= size else { return nil }
                length = Int(clamping: bytes[(start + 2) ..< (start + 10)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            }
            return Header(fin: first & 0x80 != 0, opcode: first & 0x0F, flags: (first & 0x70 != 0, second & 0x80 != 0),
                          length: length, size: size)
        }

        /// What the header alone says, before the payload is buffered: a server frame is not masked and sets no reserved
        /// bit (no extension was negotiated), its opcode fits the fragments so far, a control frame is whole and at most
        /// 125 bytes, and a message is at most `maximumMessageSize`, its fragments together.
        private func check(_ header: Header) -> Item? {
            if header.flags.reserved || header.flags.masked {
                return Self.violation("a reserved or mask bit is set")
            }
            switch header.opcode {
            case WebSocketFrame.close, WebSocketFrame.ping, WebSocketFrame.pong:
                return header.fin && header.length <= 125 ? nil : Self.violation("a fragmented or long control frame")
            case WebSocketFrame.text, WebSocketFrame.binary:
                if fragments != nil { return Self.violation("a message inside a fragmented one") }
            case 0x0:
                if fragments == nil { return Self.violation("a continuation without a message") }
            default:
                return Self.violation("the unknown opcode \(header.opcode)")
            }
            guard header.length <= maximumMessageSize - (fragments?.data.count ?? 0) else {
                return .failure(LiveKitError(.network, internalError: NSError(domain: NSPOSIXErrorDomain, code: Int(EMSGSIZE))),
                                closeCode: 1009)
            }
            return nil
        }

        /// A frame that passed `check(_:)`.
        private mutating func item(_ header: Header, _ payload: Data) -> Item? {
            switch header.opcode {
            case WebSocketFrame.text, WebSocketFrame.binary:
                fragments = (header.opcode == WebSocketFrame.text, Data())
                return append(payload, fin: header.fin)
            case WebSocketFrame.close:
                return end(Self.close(payload))
            case WebSocketFrame.ping:
                return .ping(payload)
            case WebSocketFrame.pong:
                return .pong
            default:
                return append(payload, fin: header.fin)
            }
        }

        private mutating func append(_ payload: Data, fin: Bool) -> Item? {
            fragments?.data.append(payload)
            guard fin, let message = fragments else { return nil }
            fragments = nil
            guard message.text else { return .message(.data(message.data)) }
            // Text that is not UTF-8 fails the connection (RFC 6455 §8.1), as URLSession's did.
            guard let text = String(bytes: message.data, encoding: .utf8) else {
                return end(Self.invalidPayload("a text message that is not UTF-8"))
            }
            return .message(.string(text))
        }

        private mutating func end(_ item: Item) -> Item {
            over = true
            bytes = []
            start = 0
            fragments = nil
            return item
        }

        private static func close(_ payload: Data) -> Item {
            guard payload.count >= 2 else { return payload.isEmpty ? .close(1005) : violation("a one-byte close frame") }
            let code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
            guard WebSocketFrame.isValidCloseCode(code) else { return violation("the close code \(code)") }
            guard String(bytes: payload.dropFirst(2), encoding: .utf8) != nil else {
                return invalidPayload("a close reason that is not UTF-8")
            }
            return .close(code)
        }

        private static func violation(_ reason: String) -> Item {
            failure(reason, closeCode: 1002)
        }

        private static func invalidPayload(_ reason: String) -> Item {
            failure(reason, closeCode: 1007)
        }

        /// As URLSession reported a broken stream: a POSIX protocol error.
        private static func failure(_ reason: String, closeCode: UInt16) -> Item {
            .failure(LiveKitError(.network, message: "WebSocket protocol violation: \(reason)",
                                  internalError: NSError(domain: NSPOSIXErrorDomain, code: Int(EPROTO))),
                     closeCode: closeCode)
        }
    }
}
