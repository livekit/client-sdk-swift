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

/// The signalling WebSocket, over Network.framework.
///
/// Not `URLSessionWebSocketTask`: Foundation keeps every `URLSession` that ran a WebSocket task, and the task,
/// alive after the task is cancelled and the session invalidated, whichever way it is closed (about 25 KB a
/// connection, measured on macOS 27 and the iOS 26.5 simulator). Every full or quick reconnect left one behind
/// for the life of the process. An `NWConnection` is freed once cancelled.
actor WebSocket: Loggable, AsyncSequence {
    typealias Element = URLSessionWebSocketTask.Message

    let connection: NWConnection
    /// Network.framework delivers on a queue it is given; a shared one, not one of our own: every callback here only
    /// resumes an `AsyncCompleter` or a continuation.
    private static var queue: DispatchQueue { .global(qos: .userInitiated) }

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
            connection.cancel()
            // A rejected upgrade arrives as ECONNABORTED, without its HTTP status: Network.framework does not keep
            // it. Whoever needs the status asks the validation endpoint (SignalClient, WsClientAdapter).
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
                            if let text = String(bytes: content ?? Data(), encoding: .utf8) {
                                continuation.resume(returning: .some(.string(text)))
                            } else {
                                continuation.resume(throwing: LiveKitError(.network, message: "Text frame is not valid UTF-8"))
                            }
                        case .close?:
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
}
