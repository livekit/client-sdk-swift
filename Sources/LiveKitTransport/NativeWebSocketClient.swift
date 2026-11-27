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
import LiveKitFFI

final class NativeWebSocketClient: WsClient {
    func connect(url: String, headers: [Header], timeoutMs: UInt64) async throws -> WsConnectResult {
        guard timeoutMs > 0 else { throw TransportError.Timeout }
        let url = try requestURL(url, schemes: ["ws", "wss"])
        do {
            let socket = try await WebSocket(url: url,
                                             headers: headers.map { (name: $0.name, value: $0.value) },
                                             timeoutInterval: TimeInterval(timeoutMs) / 1000)
            return WsConnectResult(connection: NativeWebSocketConnection(socket))
        } catch {
            throw error.asTransportError
        }
    }
}

private final class NativeWebSocketConnection: WsConnection {
    private let socket: WebSocket

    init(_ socket: WebSocket) {
        self.socket = socket
    }

    func send(frame: Data) async throws {
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await socket.send(data: frame)
            } onCancel: { socket.close() }
        } catch {
            throw error.asTransportError
        }
    }

    func recv() async throws -> Data? {
        do {
            // Each iterator reads the socket's one ordered inbox; skip nonbinary messages.
            // swiftformat:disable:next redundantReturn
            for try await case let .data(frame) in socket {
                return frame
            }
            return nil
        } catch {
            let transportError = error.asTransportError
            // livekit-net treats an abrupt teardown as end-of-stream, not an error:
            // a reset without a close handshake, or TLS closed without close_notify.
            if case .Closed = transportError { return nil }
            throw transportError
        }
    }

    func close() async {
        socket.close()
    }
}

extension Error {
    /// Map onto `livekit-net`'s taxonomy, which the Rust signal client branches on:
    /// `Http` is a rejected upgrade (fail fast), `Timeout`/`Closed`/`Connection` all
    /// drive a reconnect.
    var asTransportError: TransportError {
        if let transportError = self as? TransportError { return transportError }
        if self is CancellationError { return .Closed }

        let underlying = (self as? WebSocketError)?.internalError ?? self
        // The SDK's own explanation, such as a protocol violation, ahead of the code; never the system's localized text.
        let connection = { (code: String) in TransportError.Connection((self as? WebSocketError)?.message.map { "\($0) (\(code))" } ?? code) }

        // livekit-net reads a close as the end of the stream, as it always has.
        if underlying is WebSocketClosedByPeer {
            return .Closed
        }
        if let upgrade = underlying as? WebSocketUpgradeFailure {
            return .Http(status: UInt16(clamping: upgrade.statusCode))
        }
        if let urlError = underlying as? URLError {
            switch urlError.code {
            case .timedOut:
                return .Timeout
            // Our own teardown maps ECANCELED to `.cancelled`; a TCP FIN maps to
            // `.networkConnectionLost`. Both are end-of-stream to livekit-net.
            case .cancelled, .networkConnectionLost:
                return .Closed
            default:
                // The numeric code, not `localizedDescription`: this string is what Rust
                // logs and what gets grepped and grouped, and it must not change with the
                // device's language.
                return connection("URLError \(urlError.errorCode)")
            }
        }
        let nsError = underlying as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(ECONNRESET) || nsError.code == Int(ENOTCONN)
        {
            return .Closed
        }
        if let type = (self as? WebSocketError)?.type {
            switch type {
            case .timedOut: return .Timeout
            case .cancelled: return .Closed
            default: break
            }
        }
        return connection("\(nsError.domain) \(nsError.code)")
    }
}
