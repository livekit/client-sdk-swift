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

import CryptoKit
import Darwin
import Foundation
@testable import LiveKit
import Network
import Testing

/// A WebSocket server on a loopback port that answers the upgrade by hand and then misbehaves on purpose.
/// Raw TCP rather than Network.framework's own WebSocket listener, so it can send what that never would:
/// a bare FIN, a reset, an HTTP status, or nothing at all.
final class FakeWebSocketServer: Sendable {
    enum Behavior: Sendable {
        /// Upgrade, then stay quiet until the client sends a close frame, and answer it with one at once.
        case idle
        /// As `idle`, but answer the client's close frame with a binary message first, and the close frame 50 ms later.
        case messageBeforeCloseAnswer
        /// Answer the client's close frame at the client's 250 ms deadline.
        case closeAnswerAtDeadline
        /// As `idle`, but never answer the client's close frame.
        case unansweredClose
        /// Upgrade, then a close frame with code 1000, then drop the socket once the client answers it.
        case closeFrame
        /// Write these server frames and a FIN in one send, after the client's first frame or in the same send as the
        /// upgrade response; then read until the client's close frame or its FIN, and drop the socket.
        case frames(Data, withUpgrade: Bool = false)
        /// Upgrade, then one binary message of this many bytes.
        case message(size: Int)
        /// Upgrade, then a TCP FIN with no close frame.
        case fin
        /// Upgrade, then a TCP reset.
        case reset
        /// Answer the upgrade with an HTTP status instead of 101.
        case reject(status: Int)
        /// Answer the upgrade with `head`, its `{accept}` replaced with the accept value for the client's key, and `then`
        /// right behind it; then read until the client's close frame or its FIN.
        case upgradeResponse(head: String, then: Data = Data())
        /// One response per request, repeating the last if the client retries again.
        case upgradeResponses([String])
        /// Upgrade, read the first bytes that the client sends and nothing more, then send a close frame with code 1000
        /// and keep TCP open: the client's writes back up behind its unread bytes.
        case stalledReadThenClose
        /// Accept TCP and never answer the upgrade.
        case blackhole
        /// Read the TLS ClientHello record without completing the handshake.
        case tlsClientHello
    }

    let behavior: Behavior
    let acceptCount = StateSync(0)
    let clientHello = AsyncCompleter<Data>(label: "FakeWebSocketServer.clientHello", defaultTimeout: 5)
    /// Resumed once the listener has accepted a TCP connection, before any upgrade is read.
    let accepted = AsyncCompleter<Void>(label: "FakeWebSocketServer.accepted", defaultTimeout: 5)
    /// Resumed once the server has finished with a connection: sent its last bytes or dropped the socket.
    let served = AsyncCompleter<Void>(label: "FakeWebSocketServer.served", defaultTimeout: 5)
    /// The header lines of the last upgrade request, the request line excluded.
    let requestHeaders = StateSync<[String]>([])
    let requests = StateSync<[(line: String, headers: [String])]>([])
    /// A frame from the client, unmasked.
    struct ClientFrame: Sendable {
        let opcode: UInt8
        let payload: Data
        /// Whether it came masked, as every client frame must.
        let masked: Bool
        let compressed: Bool
    }

    /// The client's frames, in the order they arrived.
    let frames = StateSync<[ClientFrame]>([])
    let closeAnswered = StateSync<UInt64?>(nil)
    /// Resumed with the time, in `DispatchTime` uptime nanoseconds, the client dropped TCP after its close frame.
    let clientGone = AsyncCompleter<UInt64>(label: "FakeWebSocketServer.clientGone", defaultTimeout: 5)

    private let listener: NWListener
    /// Network.framework delivers on a queue it is given; a shared one, as the transport under test uses.
    private static var queue: DispatchQueue { .global(qos: .default) }
    private let ready = AsyncCompleter<UInt16>(label: "FakeWebSocketServer.ready", defaultTimeout: 5)
    private let connections = StateSync<[NWConnection]>([])

    init(_ behavior: Behavior) throws {
        self.behavior = behavior
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [ready, listener] state in
            switch state {
            case .ready: ready.resume(returning: listener.port?.rawValue ?? 0)
            case let .failed(error): ready.resume(throwing: error)
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            acceptCount.mutate { $0 += 1 }
            connections.mutate { $0.append(connection) }
            connection.start(queue: Self.queue)
            accepted.resume(returning: ())
            if case .blackhole = behavior { return }
            if case .tlsClientHello = behavior { return readClientHello(connection, buffered: Data()) }
            readUpgrade(connection, buffered: Data())
        }
        listener.start(queue: Self.queue)
    }

    /// A ready server, replacing listeners that lose their port to a transient collision.
    static func started(_ behavior: Behavior) async throws -> (server: FakeWebSocketServer, url: URL) {
        var retries = 3
        while true {
            let server = try FakeWebSocketServer(behavior)
            do {
                return try await (server, server.url())
            } catch {
                server.cancel()
                guard case .posix(.EADDRINUSE) = error as? NWError, retries > 0 else { throw error }
                retries -= 1
            }
        }
    }

    /// `host` as it goes in a URL: an IPv6 address in brackets.
    func url(host: String = "127.0.0.1") async throws -> URL {
        let port = try await ready.wait()
        return try #require(URL(string: "ws://\(host):\(port)/rtc"))
    }

    /// Drops every connection and the listener; safe to call more than once.
    func cancel() {
        connections.mutate { $0.forEach { $0.cancel() }; $0.removeAll() }
        if listener.stateUpdateHandler != nil { listener.stateUpdateHandler = nil }
        if listener.newConnectionHandler != nil { listener.newConnectionHandler = nil }
        listener.cancel()
    }

    private func readClientHello(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] content, _, _, error in
            guard error == nil, let content, !content.isEmpty else {
                clientHello.resume(throwing: error ?? LiveKitError(.network))
                return
            }
            let record = buffered + content
            if record.count >= 5 {
                let length = Int(record[3]) << 8 | Int(record[4])
                if record.count >= 5 + length {
                    clientHello.resume(returning: Data(record.prefix(5 + length)))
                    return
                }
            }
            readClientHello(connection, buffered: record)
        }
    }

    private func readUpgrade(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] content, _, _, error in
            guard error == nil, let content else { return connection.cancel() }
            let request = buffered + content
            guard let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) else {
                return readUpgrade(connection, buffered: request)
            }
            let header = String(bytes: request[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let allLines = header.components(separatedBy: "\r\n")
            let lines = allLines.dropFirst()
            requestHeaders.mutate { $0 = Array(lines) }
            let index = requests.mutate {
                let index = $0.count
                $0.append((allLines.first ?? "", Array(lines)))
                return index
            }
            let key = lines
                .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
            answer(connection, key: key, index: index)
        }
    }

    private func answer(_ connection: NWConnection, key: String, index: Int) {
        if case let .reject(status) = behavior {
            let response = "HTTP/1.1 \(status) Rejected\r\nContent-Length: 0\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [served] _ in
                connection.cancel()
                served.resume(returning: ())
            })
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        if let response = customResponse(index: index, accept: accept) {
            connection.send(content: response, completion: .contentProcessed { [self] _ in readUntilClose(connection, buffered: Data()) })
            return
        }
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        if case let .frames(bytes, true) = behavior {
            connection.send(content: Data(response.utf8) + bytes, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [self] _ in readUntilClose(connection, buffered: Data()) })
            return
        }
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [self] _ in
            switch behavior {
            case .blackhole, .tlsClientHello, .reject, .upgradeResponse, .upgradeResponses:
                break
            case .idle, .messageBeforeCloseAnswer, .closeAnswerAtDeadline, .unansweredClose:
                answerClose(connection, buffered: Data())
            case .stalledReadThenClose:
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [served] _, _, _, _ in
                    connection.send(content: Self.close(1000), completion: .contentProcessed { _ in served.resume(returning: ()) })
                }
            case .closeFrame, .frames, .message, .fin, .reset:
                // Only once a whole frame arrives from the client: its upgrade is then complete on its side too.
                readFrame(connection, buffered: Data()) { [self] _, _ in goAway(connection) }
            }
        })
    }

    /// Reads one complete client frame, however the bytes arrive, records it, then calls `completion` with its opcode
    /// and the bytes that follow it. A client frame is masked: two header bytes, a 16-bit length when the 7-bit one is
    /// 126, a 4-byte mask key, then the payload.
    private func readFrame(_ connection: NWConnection, buffered: Data, onEnd: (@Sendable () -> Void)? = nil,
                           completion: @escaping @Sendable (_ opcode: UInt8, _ rest: Data) -> Void)
    {
        let bytes = [UInt8](buffered)
        if bytes.count >= 2, bytes[1] & 0x7F == 127 { return connection.cancel() }
        let lengthEnd = bytes.count >= 2 && bytes[1] & 0x7F == 126 ? 4 : 2
        if bytes.count >= lengthEnd {
            let length = lengthEnd == 4 ? Int(bytes[2]) << 8 | Int(bytes[3]) : Int(bytes[1] & 0x7F)
            let maskEnd = lengthEnd + (bytes[1] & 0x80 != 0 ? 4 : 0)
            if bytes.count >= maskEnd + length {
                let mask = maskEnd > lengthEnd ? Array(bytes[lengthEnd ..< maskEnd]) : [0, 0, 0, 0]
                let payload = Data(bytes[maskEnd ..< maskEnd + length].enumerated().map { $1 ^ mask[$0 % 4] })
                frames.mutate { $0.append(ClientFrame(opcode: bytes[0] & 0x0F, payload: payload, masked: maskEnd > lengthEnd, compressed: bytes[0] & 0x40 != 0)) }
                return completion(bytes[0] & 0x0F, Data(bytes[(maskEnd + length)...]))
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] content, _, _, error in
            guard error == nil, let content, !content.isEmpty else {
                if let onEnd { onEnd() } else { connection.cancel() }
                return
            }
            readFrame(connection, buffered: buffered + content, onEnd: onEnd, completion: completion)
        }
    }

    /// Answers the client's close frame as `behavior` says and keeps the socket open: the client must drop it.
    private func answerClose(_ connection: NWConnection, buffered: Data) {
        readFrame(connection, buffered: buffered) { [self] opcode, rest in
            guard opcode == 0x8 else { return answerClose(connection, buffered: rest) }
            awaitTeardown(connection, buffered: rest)
            switch behavior {
            case .messageBeforeCloseAnswer:
                connection.send(content: Data([0x82, 0x01, 0x00]), completion: .contentProcessed { _ in })
                Self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in sendCloseAnswer(connection) }
            case .closeAnswerAtDeadline:
                Self.queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in sendCloseAnswer(connection) }
            case .unansweredClose:
                break
            default:
                sendCloseAnswer(connection)
            }
        }
    }

    private func sendCloseAnswer(_ connection: NWConnection) {
        closeAnswered.mutate { $0 = DispatchTime.now().uptimeNanoseconds }
        connection.send(content: Data([0x88, 0x02, 0x03, 0xE8]), completion: .contentProcessed { [served] _ in
            served.resume(returning: ())
        })
    }

    /// Reads on until the client's FIN or reset.
    private func awaitTeardown(_ connection: NWConnection, buffered: Data) {
        readFrame(connection, buffered: buffered, onEnd: { [clientGone] in
            clientGone.resume(returning: DispatchTime.now().uptimeNanoseconds)
        }) { [self] _, rest in
            awaitTeardown(connection, buffered: rest)
        }
    }

    private func goAway(_ connection: NWConnection) {
        switch behavior {
        case .idle, .messageBeforeCloseAnswer, .closeAnswerAtDeadline, .unansweredClose, .blackhole, .tlsClientHello, .reject,
             .upgradeResponse, .upgradeResponses, .stalledReadThenClose:
            break
        case let .frames(bytes, _):
            connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
                readUntilClose(connection, buffered: Data())
            })
        case .closeFrame:
            connection.send(content: Self.close(1000), completion: .contentProcessed { [self] _ in
                // The client's whole close reply, then the socket goes: the client sees a state change after its stream ended.
                readFrame(connection, buffered: Data()) { [served] _, _ in
                    connection.cancel()
                    served.resume(returning: ())
                }
            })
        case let .message(size):
            // A server frame is not masked; 127 takes a 64-bit length.
            let header: [UInt8] = [UInt8(0x82), 127] + (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: UInt64(size) >> ($0 * 8)) }
            connection.send(content: Data(header) + Data(count: size), completion: .contentProcessed { [served] _ in
                served.resume(returning: ())
            })
        case .fin:
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [served] _ in
                served.resume(returning: ())
            })
        case .reset:
            connection.forceCancel()
            served.resume(returning: ())
        }
    }

    private func readUntilClose(_ connection: NWConnection, buffered: Data) {
        let done: @Sendable () -> Void = { [served] in
            connection.cancel()
            served.resume(returning: ())
        }
        readFrame(connection, buffered: buffered, onEnd: done) { [self] opcode, rest in
            opcode == 0x8 ? done() : readUntilClose(connection, buffered: rest)
        }
    }
}

extension FakeWebSocketServer {
    static func unusedTCPPort() throws -> UInt16 {
        let automaticStart = try #require(try ["first", "last", "hifirst", "hilast"].map { name in
            var value: Int32 = 0
            var size = MemoryLayout.size(ofValue: value)
            try #require(sysctlbyname("net.inet.ip.portrange.\(name)", &value, &size, nil, 0) == 0)
            return value
        }.min())
        try #require(automaticStart > 1024 && automaticStart <= UInt16.max)
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        for port in (UInt16(1024) ..< UInt16(automaticStart)).shuffled() {
            address.sin_port = port.bigEndian
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 { return port }
            try #require(errno == EADDRINUSE)
        }
        return try #require(nil as UInt16?, "No unused destination outside automatic source-port ranges")
    }

    /// A server frame with an unmasked payload and the shortest length encoding.
    static func frame(_ opcode: UInt8, _ payload: Data, final: Bool = true) -> Data {
        let length: [UInt8] = switch payload.count {
        case ..<126:
            [UInt8(payload.count)]
        case ...0xFFFF:
            [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            [127] + (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) }
        }
        let fin: UInt8 = final ? 0x80 : 0
        return Data([fin | opcode] + length) + payload
    }

    /// Binary messages, one per payload.
    static func binary(_ payloads: [Data]) -> Data {
        payloads.reduce(into: Data()) { $0 += frame(0x2, $1) }
    }

    static func close(_ code: UInt16, reason: String = "") -> Data {
        frame(0x8, Data([UInt8(code >> 8), UInt8(code & 0xFF)]) + Data(reason.utf8))
    }

    private func customResponse(index: Int, accept: String) -> Data? {
        let head: String
        let then: Data
        switch behavior {
        case let .upgradeResponse(response, bytes):
            head = response
            then = bytes
        case let .upgradeResponses(responses):
            head = responses.dropFirst(index).first ?? responses.last ?? "HTTP/1.1 500 Empty fixture\r\n\r\n"
            then = Data()
        default:
            return nil
        }
        let response = head.replacingOccurrences(of: "{accept}", with: accept)
            .replacingOccurrences(of: "{port}", with: listener.port.map { String($0.rawValue) } ?? "0")
        return Data(response.utf8) + then
    }
}
