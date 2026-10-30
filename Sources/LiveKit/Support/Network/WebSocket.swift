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
import Network

/// The server answered the upgrade request with an HTTP response instead of switching
/// protocols. Carried as the `internalError` of the thrown ``LiveKitError``.
struct WebSocketUpgradeFailure: Error, Sendable {
    let statusCode: Int
}

/// The signalling WebSocket, over Network.framework.
///
/// Not `URLSessionWebSocketTask`: Foundation keeps every `URLSession` that ran a WebSocket task, and the task,
/// alive after the task is cancelled and the session invalidated, whichever way it is closed (about 25 KB a
/// connection, measured on macOS 27 and the iOS 26.5 simulator). Every full or quick reconnect left one behind
/// for the life of the process. An `NWConnection` is freed once cancelled.
actor WebSocket: Loggable, AsyncSequence {
    typealias Element = URLSessionWebSocketTask.Message
    typealias EventHandler = @Sendable (Event) -> Void

    let connection: NWConnection
    enum Event: Sendable {
        case receiveRegistered
        case closeStarted
        case teardown
        case closeDeadline
    }

    fileprivate enum Lifecycle: Sendable { case open, closing, closed }

    private let lifecycle = StateSync(Lifecycle.open)
    private let onEvent: EventHandler?
    /// Network.framework delivers on a queue it is given; a shared one, not one of our own: every callback here only
    /// resumes an `AsyncCompleter` or a continuation.
    private static var queue: DispatchQueue { .global(qos: .default) }

    static func makeParameters(secure: Bool, timeoutInterval: TimeInterval) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Swift.max(1, Int(timeoutInterval.rounded(.up)))
        // URLSession turned Nagle off; signal messages are small.
        tcp.noDelay = true
        let parameters = NWParameters(tls: secure ? NWProtocolTLS.Options() : nil, tcp: tcp)
        // As `.callSignaling` on the URLSession configuration this replaces.
        parameters.serviceClass = .signaling
        #if os(iOS) || os(visionOS)
        // https://developer.apple.com/documentation/foundation/urlsessionconfiguration/improving_network_reliability_using_multipath_tcp
        parameters.multipathServiceType = .handover
        #endif
        return parameters
    }

    init(url: URL, headers: [(name: String, value: String)], timeoutInterval: TimeInterval,
         onEvent: EventHandler? = nil) async throws
    {
        self.onEvent = onEvent
        #if targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            nw_tls_create_options()
        }
        #endif

        let headers = Self.upgradeHeaders(url: url, headers: headers)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        // URLSessionWebSocketTask's limit on a received message.
        webSocket.maximumMessageSize = 1 << 20
        webSocket.setAdditionalHeaders(headers)
        let parameters = Self.makeParameters(secure: url.scheme == "wss", timeoutInterval: timeoutInterval)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection

        let opening = AsyncCompleter<Void>(label: "WebSocket.open", defaultTimeout: timeoutInterval)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                opening.resume(returning: ())
            case let .failed(error), let .waiting(error):
                // `.waiting` too: a connection that cannot be made now fails, as URLSession's did
                // (waitsForConnectivity off); the signal client owns the retries.
                opening.resume(with: .failure(error))
            case .cancelled:
                opening.resume(with: .failure(LiveKitError(.cancelled)))
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
        do {
            try await opening.wait()
        } catch let error as NWError {
            Self.finish(connection, lifecycle, onEvent)
            // The server answered the upgrade with an HTTP status: Network.framework aborts the connection
            // without it, so the same upgrade, sent once more by hand, reads it.
            if case .posix(.ECONNABORTED) = error,
               let status = await Self.upgradeStatus(url: url, headers: headers, timeoutInterval: timeoutInterval)
            {
                throw LiveKitError(.network, internalError: WebSocketUpgradeFailure(statusCode: status))
            }
            throw LiveKitError(.network, internalError: Self.bridged(error))
        } catch {
            Self.finish(connection, lifecycle, onEvent)
            throw error is LiveKitError ? error : LiveKitError.from(error: error) ?? LiveKitError(.unknown)
        }
    }

    deinit {
        Self.close(connection, lifecycle, onEvent)
    }

    /// Sends a close frame with code 1000, as `URLSessionWebSocketTask.cancel(with: .normalClosure)` did, and cancels
    /// once the server answers or after 250 ms (the JS SDK's wait), whichever comes first. Does not block. New reads
    /// end immediately; a pending receive ends on whatever arrives next, at the latest on the server's reply or the
    /// deadline. Only the first call does anything.
    nonisolated func close() {
        Self.close(connection, lifecycle, onEvent)
    }

    fileprivate static func close(_ connection: NWConnection, _ lifecycle: StateSync<Lifecycle>, _ onEvent: EventHandler?) {
        guard lifecycle.mutate({
            guard $0 == .open else { return false }
            $0 = .closing
            return true
        }) else { return }
        onEvent?(.closeStarted)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            drain(connection, lifecycle, onEvent)
        })
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
            finish(connection, lifecycle, onEvent)
            onEvent?(.closeDeadline)
        }
    }

    /// Drops the messages still in flight and cancels once the close handshake is over.
    private static func drain(_ connection: NWConnection, _ lifecycle: StateSync<Lifecycle>, _ onEvent: EventHandler?) {
        guard lifecycle.copy() == .closing else { return }
        connection.receiveMessage { _, context, _, error in
            endsClose(context, error) ? finish(connection, lifecycle, onEvent) : drain(connection, lifecycle, onEvent)
        }
    }

    fileprivate static func finish(_ connection: NWConnection, _ lifecycle: StateSync<Lifecycle>, _ onEvent: EventHandler?) {
        guard lifecycle.mutate({
            guard $0 != .closed else { return false }
            $0 = .closed
            return true
        }) else { return }
        onEvent?(.teardown)
        cancel(connection)
    }

    /// Whether a receive after our close frame ends the handshake: the server's close frame, an error, or the end of the
    /// stream (no WebSocket metadata).
    fileprivate static func endsClose(_ context: NWConnection.ContentContext?, _ error: NWError?) -> Bool {
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
        return error != nil || metadata.map { $0.opcode == .close } ?? true
    }

    /// Below iOS 16 and macOS 13 a cancelled connection keeps its state handler, and whatever that captures.
    fileprivate static func cancel(_ connection: NWConnection) {
        connection.cancel()
        connection.stateUpdateHandler = nil
    }

    /// The upgrade headers as URLSession sent them. A repeated name is joined with commas, as `URLRequest.addValue`
    /// did (`setAdditionalHeaders` keeps only the last value). The cookies stored for the URL go along, matched on
    /// its `https` form so that secure ones count. `Host` carries the port and IPv6 brackets, which Network.framework's
    /// own drops; it comes last, after the join, so it replaces the generated one and any the caller passed.
    static func upgradeHeaders(url: URL, headers: [(name: String, value: String)]) -> [(name: String, value: String)] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = url.scheme == "wss" ? "https" : "http"
        let cookies = components?.url.flatMap { HTTPCookieStorage.shared.cookies(for: $0) } ?? []
        let stored = HTTPCookie.requestHeaderFields(with: cookies).map { (name: $0.key, value: $0.value) }

        var joined: [(name: String, value: String)] = []
        for (name, value) in headers + stored where name.caseInsensitiveCompare("Host") != .orderedSame {
            if let index = joined.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                joined[index].value += (name.caseInsensitiveCompare("Cookie") == .orderedSame ? "; " : ",") + value
            } else {
                joined.append((name, value))
            }
        }
        guard let host = url.host else { return joined }
        let port = url.port.map { ":\($0)" } ?? ""
        return joined + [(name: "Host", value: (host.contains(":") ? "[\(host)]" : host) + port)]
    }

    /// The HTTP status the server answers the upgrade with, read off the status line of the same request sent over
    /// a plain TCP (and TLS) connection; nil when it gives none or switches protocols after all. `headers` are the
    /// ``upgradeHeaders(url:headers:)``, `Host` included.
    static func upgradeStatus(url: URL, headers: [(name: String, value: String)], timeoutInterval: TimeInterval) async -> Int? {
        guard let host = url.host else { return nil }
        let secure = url.scheme == "wss"
        let port = url.port ?? (secure ? 443 : 80)
        // The request target as the upgrade sent it: escaped, as `URL.path` would not give it.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?\(query)" }
        let key = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }).base64EncodedString()
        var request = "GET \(target) HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        for (name, value) in headers {
            request += "\(name): \(value)\r\n"
        }
        request += "\r\n"
        let bytes = Data(request.utf8)

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: makeParameters(secure: secure, timeoutInterval: timeoutInterval))
        defer { cancel(connection) }
        let answer = AsyncCompleter<Int?>(label: "WebSocket.upgradeStatus", defaultTimeout: timeoutInterval)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: bytes, completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 12, maximumLength: 512) { content, _, _, _ in
                    // "HTTP/1.1 401 Unauthorized"
                    let line = content.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first
                    let status = line.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) }
                    answer.resume(returning: status == 101 ? nil : status)
                }
            case .failed, .waiting, .cancelled:
                answer.resume(returning: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        return try? await answer.wait()
    }

    /// Network.framework's errors in the shapes the SDK reads elsewhere (`isNetworkError`, `asTransportError`):
    /// a timeout as `URLError(.timedOut)`, any other POSIX code as an `NSPOSIXErrorDomain` error.
    static func bridged(_ error: NWError) -> Error {
        switch error {
        case .posix(.ETIMEDOUT):
            URLError(.timedOut)
        case let .posix(code):
            NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
        default:
            error
        }
    }

    // MARK: - AsyncSequence

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let connection: NWConnection
        fileprivate let lifecycle: StateSync<Lifecycle>
        fileprivate let onEvent: EventHandler?

        func next() async throws -> URLSessionWebSocketTask.Message? {
            while lifecycle.copy() == .open {
                guard let frame = try await receive() else { return nil }
                if let message = frame { return message }
                // A control frame (ping, pong): not a message; read on.
            }
            return nil
        }

        /// nil at the end of the stream, `.some(nil)` for a frame that is not a message.
        private func receive() async throws -> URLSessionWebSocketTask.Message?? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLSessionWebSocketTask.Message??, Error>) in
                    connection.receiveMessage { content, context, _, error in
                        // Our own close ends the sequence, as a cancelled task's did, whatever arrives after it. This
                        // receive can be the one that takes the server's answer, ahead of the close path's own.
                        if lifecycle.copy() != .open {
                            if WebSocket.endsClose(context, error) { WebSocket.finish(connection, lifecycle, onEvent) }
                            return continuation.resume(returning: nil)
                        }
                        if let error {
                            WebSocket.finish(connection, lifecycle, onEvent)
                            return continuation.resume(throwing: LiveKitError(.network, internalError: WebSocket.bridged(error)))
                        }
                        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                        switch metadata?.opcode {
                        case .binary?:
                            continuation.resume(returning: .some(.data(content ?? Data())))
                        case .text?:
                            if let text = String(bytes: content ?? Data(), encoding: .utf8) {
                                continuation.resume(returning: .some(.string(text)))
                            } else {
                                continuation.resume(throwing: LiveKitError(.network, message: "Text frame is not valid UTF-8"))
                            }
                        case .close?:
                            WebSocket.finish(connection, lifecycle, onEvent)
                            continuation.resume(returning: nil)
                        case nil where content?.isEmpty ?? true:
                            // A TCP FIN with no close frame: the end of the stream, which fails the sequence.
                            WebSocket.finish(connection, lifecycle, onEvent)
                            continuation.resume(throwing: LiveKitError(.network, internalError: URLError(.networkConnectionLost)))
                        default:
                            continuation.resume(returning: .some(nil))
                        }
                    }
                    onEvent?(.receiveRegistered)
                }
            } onCancel: {
                // As the URLSession task's `cancel(with: .normalClosure)`: `SignalClient.cleanUp` cancels the
                // read before it calls `close()`.
                WebSocket.close(connection, lifecycle, onEvent)
            }
        }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(connection: connection, lifecycle: lifecycle, onEvent: onEvent)
    }

    // MARK: - Send

    nonisolated func send(data: Data) async throws {
        let context = NWConnection.ContentContext(identifier: "binary",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: LiveKitError(.network, internalError: WebSocket.bridged(error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
