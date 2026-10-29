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
        /// As `idle`, but never answer the client's close frame.
        case unansweredClose
        /// Upgrade, then a close frame with code 1000, then drop the socket once the client answers it.
        case closeFrame
        /// Upgrade, then one binary message of this many bytes.
        case message(size: Int)
        /// Upgrade, then a TCP FIN with no close frame.
        case fin
        /// Upgrade, then a TCP reset.
        case reset
        /// Answer the upgrade with an HTTP status instead of 101.
        case reject(status: Int)
        /// Accept TCP and never answer the upgrade.
        case blackhole
    }

    let behavior: Behavior
    /// Resumed once the listener has accepted a TCP connection, before any upgrade is read.
    let accepted = AsyncCompleter<Void>(label: "FakeWebSocketServer.accepted", defaultTimeout: 5)
    /// Resumed once the server has finished with a connection: sent its last bytes or dropped the socket.
    let served = AsyncCompleter<Void>(label: "FakeWebSocketServer.served", defaultTimeout: 5)
    /// The header lines of the last upgrade request, the request line excluded.
    let requestHeaders = StateSync<[String]>([])
    /// The client's frames, unmasked, in the order they arrived.
    let frames = StateSync<[(opcode: UInt8, payload: Data)]>([])
    /// When the server answered the client's close frame, in `DispatchTime` uptime nanoseconds.
    let closeAnswered = StateSync<UInt64?>(nil)
    /// Resumed with the time, in `DispatchTime` uptime nanoseconds, the client dropped TCP after its close frame.
    let clientGone = AsyncCompleter<UInt64>(label: "FakeWebSocketServer.clientGone", defaultTimeout: 5)

    private let listener: NWListener
    /// Network.framework delivers on a queue it is given; a shared one, as the transport under test uses.
    private static var queue: DispatchQueue { .global(qos: .default) }
    private let ready = AsyncCompleter<UInt16>(label: "FakeWebSocketServer.ready", defaultTimeout: 5)
    private let stopped = AsyncCompleter<Void>(label: "FakeWebSocketServer.stopped", defaultTimeout: 5)
    private let connections = StateSync<[NWConnection]>([])

    init(_ behavior: Behavior) throws {
        self.behavior = behavior
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [ready, stopped, listener] state in
            switch state {
            case .ready: ready.resume(returning: listener.port?.rawValue ?? 0)
            case let .failed(error): ready.resume(throwing: error)
            case .cancelled:
                // Below iOS 16 and macOS 13 a cancelled listener keeps its handlers; this one captures the listener.
                listener.stateUpdateHandler = nil
                stopped.resume(returning: ())
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connections.mutate { $0.append(connection) }
            connection.start(queue: Self.queue)
            accepted.resume(returning: ())
            if case .blackhole = behavior { return }
            readUpgrade(connection, buffered: Data())
        }
        listener.start(queue: Self.queue)
    }

    /// `host` as it goes in a URL: an IPv6 address in brackets.
    func url(host: String = "127.0.0.1") async throws -> URL {
        let port = try await ready.wait()
        return try #require(URL(string: "ws://\(host):\(port)/rtc"))
    }

    /// Drops every connection and the listener; safe to call more than once.
    func cancel() {
        connections.mutate { $0.forEach { $0.cancel() }; $0.removeAll() }
        listener.cancel()
        // It captures the server, which holds the listener.
        listener.newConnectionHandler = nil
    }

    /// Returns once the port refuses connections again.
    func stop() async throws {
        cancel()
        try await stopped.wait()
    }

    private func readUpgrade(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] content, _, _, error in
            guard error == nil, let content else { return connection.cancel() }
            let request = buffered + content
            guard let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) else {
                return readUpgrade(connection, buffered: request)
            }
            let header = String(bytes: request[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let lines = header.components(separatedBy: "\r\n").dropFirst()
            requestHeaders.mutate { $0 = Array(lines) }
            let key = lines
                .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
            answer(connection, key: key)
        }
    }

    private func answer(_ connection: NWConnection, key: String) {
        if case let .reject(status) = behavior {
            let response = "HTTP/1.1 \(status) Rejected\r\nContent-Length: 0\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [served] _ in
                connection.cancel()
                served.resume(returning: ())
            })
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [self] _ in
            switch behavior {
            case .blackhole, .reject:
                break
            case .idle, .messageBeforeCloseAnswer, .unansweredClose:
                answerClose(connection, buffered: Data())
            case .closeFrame, .message, .fin, .reset:
                // Only once a whole frame arrives from the client: its upgrade is then complete on its side too.
                readFrame(connection, buffered: Data()) { [self] _, _ in goAway(connection) }
            }
        })
    }

    /// Reads one complete client frame, however the bytes arrive, records it, then calls `completion` with its opcode
    /// and the bytes that follow it. A client frame is masked: two header bytes, a 16-bit length when the 7-bit one is
    /// 126, a 4-byte mask key, then the payload.
    private func readFrame(_ connection: NWConnection, buffered: Data, completion: @escaping @Sendable (_ opcode: UInt8, _ rest: Data) -> Void) {
        let bytes = [UInt8](buffered)
        if bytes.count >= 2, bytes[1] & 0x7F == 127 { return connection.cancel() }
        let lengthEnd = bytes.count >= 2 && bytes[1] & 0x7F == 126 ? 4 : 2
        if bytes.count >= lengthEnd {
            let length = lengthEnd == 4 ? Int(bytes[2]) << 8 | Int(bytes[3]) : Int(bytes[1] & 0x7F)
            let maskEnd = lengthEnd + (bytes[1] & 0x80 != 0 ? 4 : 0)
            if bytes.count >= maskEnd + length {
                let mask = maskEnd > lengthEnd ? Array(bytes[lengthEnd ..< maskEnd]) : [0, 0, 0, 0]
                let payload = Data(bytes[maskEnd ..< maskEnd + length].enumerated().map { $1 ^ mask[$0 % 4] })
                frames.mutate { $0.append((opcode: bytes[0] & 0x0F, payload: payload)) }
                return completion(bytes[0] & 0x0F, Data(bytes[(maskEnd + length)...]))
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] content, _, _, error in
            guard error == nil, let content else { return connection.cancel() }
            readFrame(connection, buffered: buffered + content, completion: completion)
        }
    }

    /// Answers the client's close frame as `behavior` says and keeps the socket open: the client must drop it.
    private func answerClose(_ connection: NWConnection, buffered: Data) {
        readFrame(connection, buffered: buffered) { [self] opcode, rest in
            guard opcode == 0x8 else { return answerClose(connection, buffered: rest) }
            awaitTeardown(connection)
            switch behavior {
            case .messageBeforeCloseAnswer:
                connection.send(content: Data([0x82, 0x01, 0x00]), completion: .contentProcessed { _ in })
                Self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in sendCloseAnswer(connection) }
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
    private func awaitTeardown(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] content, _, _, error in
            guard error != nil || content?.isEmpty ?? true else { return awaitTeardown(connection) }
            clientGone.resume(returning: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private func goAway(_ connection: NWConnection) {
        switch behavior {
        case .idle, .messageBeforeCloseAnswer, .unansweredClose, .blackhole, .reject:
            break
        case .closeFrame:
            connection.send(content: Data([0x88, 0x02, 0x03, 0xE8]), completion: .contentProcessed { [self] _ in
                // The client's whole close reply, then the socket goes: the client sees a state change after its stream ended.
                readFrame(connection, buffered: Data()) { [served] _, _ in
                    connection.cancel()
                    served.resume(returning: ())
                }
            })
        case let .message(size):
            // A server frame is not masked; 127 takes a 64-bit length.
            let header: [UInt8] = [0x82, 127] + (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: UInt64(size) >> ($0 * 8)) }
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
}
