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

    private let connection: NWConnection
    private static let queue = DispatchQueue(label: "LiveKitSDK.webSocket")

    /// Every header entry is added, not set, so a repeated name keeps all of its values.
    static func makeRequest(url: URL, headers: [(name: String, value: String)], timeoutInterval: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url,
                                 cachePolicy: .useProtocolCachePolicy,
                                 timeoutInterval: timeoutInterval)
        for (name, value) in headers {
            request.addValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    static func makeParameters(secure: Bool, timeoutInterval: TimeInterval) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Swift.max(1, Int(timeoutInterval.rounded(.up)))
        let parameters = NWParameters(tls: secure ? NWProtocolTLS.Options() : nil, tcp: tcp)
        // As `.callSignaling` on the URLSession configuration this replaces.
        parameters.serviceClass = .responsiveData
        #if os(iOS) || os(visionOS)
        // https://developer.apple.com/documentation/foundation/urlsessionconfiguration/improving_network_reliability_using_multipath_tcp
        parameters.multipathServiceType = .handover
        #endif
        return parameters
    }

    init(url: URL, headers: [(name: String, value: String)], timeoutInterval: TimeInterval) async throws {
        #if targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            nw_tls_create_options()
        }
        #endif

        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 0 // no limit, as URLSessionWebSocketTask's 1 MB default would have been raised
        webSocket.setAdditionalHeaders(headers)
        let parameters = Self.makeParameters(secure: url.scheme == "wss", timeoutInterval: timeoutInterval)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection

        let opening = Once<Void>()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    opening.start(continuation)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            opening.finish(.success(()))
                        case let .failed(error), let .waiting(error):
                            // `.waiting` too: a connection that cannot be made now fails, as URLSession's did
                            // (waitsForConnectivity off); the signal client owns the retries.
                            opening.finish(.failure(error))
                        case .cancelled:
                            opening.finish(.failure(LiveKitError(.cancelled)))
                        default:
                            break
                        }
                    }
                    connection.start(queue: Self.queue)
                    Self.queue.asyncAfter(deadline: .now() + timeoutInterval) {
                        opening.finish(.failure(URLError(.timedOut)))
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        } catch let error as NWError {
            connection.cancel()
            // The server answered the upgrade with an HTTP status: Network.framework aborts the connection
            // without it, so the same upgrade, sent once more by hand, reads it.
            if case .posix(.ECONNABORTED) = error,
               let status = await Self.upgradeStatus(url: url, headers: headers, timeoutInterval: timeoutInterval)
            {
                throw LiveKitError(.network, internalError: WebSocketUpgradeFailure(statusCode: status))
            }
            throw LiveKitError(.network, internalError: Self.bridged(error))
        } catch {
            connection.cancel()
            throw error is LiveKitError ? error : LiveKitError.from(error: error) ?? LiveKitError(.unknown)
        }
    }

    deinit {
        connection.cancel()
    }

    nonisolated func close() {
        connection.cancel()
    }

    /// The HTTP status the server answers the upgrade with, read off the status line of the same request sent over
    /// a plain TCP (and TLS) connection; nil when it gives none or switches protocols after all.
    static func upgradeStatus(url: URL, headers: [(name: String, value: String)], timeoutInterval: TimeInterval) async -> Int? {
        guard let host = url.host else { return nil }
        let secure = url.scheme == "wss"
        let port = url.port ?? (secure ? 443 : 80)
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?\(query)" }
        let key = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }).base64EncodedString()
        var request = "GET \(target) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        let bytes = Data(request.utf8)

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: makeParameters(secure: secure, timeoutInterval: timeoutInterval))
        defer { connection.cancel() }
        let answer = Once<Int?>()
        return try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int?, Error>) in
            answer.start(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: bytes, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 12, maximumLength: 512) { content, _, _, _ in
                        // "HTTP/1.1 401 Unauthorized"
                        let line = content.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first
                        let status = line.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) }
                        answer.finish(.success(status == 101 ? nil : status))
                    }
                case .failed, .waiting, .cancelled:
                    answer.finish(.success(nil))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutInterval) { answer.finish(.success(nil)) }
        }
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

        func next() async throws -> URLSessionWebSocketTask.Message? {
            while true {
                guard let frame = try await receive() else { return nil }
                if let message = frame { return message }
                // A control frame (ping, pong): not a message; read on.
            }
        }

        /// nil at the end of the stream, `.some(nil)` for a frame that is not a message.
        private func receive() async throws -> URLSessionWebSocketTask.Message?? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLSessionWebSocketTask.Message??, Error>) in
                    connection.receiveMessage { content, context, _, error in
                        if let error {
                            // Our own close ends the sequence, as a cancelled task's did, rather than failing it.
                            if case .posix(.ECANCELED) = error { return continuation.resume(returning: nil) }
                            return continuation.resume(throwing: LiveKitError(.network, internalError: WebSocket.bridged(error)))
                        }
                        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                        switch metadata?.opcode {
                        case .binary?:
                            continuation.resume(returning: .some(.data(content ?? Data())))
                        case .text?:
                            continuation.resume(returning: .some(.string(String(decoding: content ?? Data(), as: UTF8.self))))
                        case .close?, nil:
                            continuation.resume(returning: nil)
                        default:
                            continuation.resume(returning: .some(nil))
                        }
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(connection: connection)
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

    // MARK: - Opening

    /// A continuation resumed once, by whichever comes first: the connection's answer or the timeout.
    private final class Once<Value: Sendable>: Sendable {
        private let continuation = StateSync<CheckedContinuation<Value, Error>?>(nil)

        func start(_ continuation: CheckedContinuation<Value, Error>) {
            self.continuation.mutate { $0 = continuation }
        }

        func finish(_ result: Result<Value, Error>) {
            let pending = continuation.mutate { current -> CheckedContinuation<Value, Error>? in
                defer { current = nil }
                return current
            }
            pending?.resume(with: result)
        }
    }
}
