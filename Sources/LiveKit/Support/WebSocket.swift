/*
 * Copyright 2025 LiveKit
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

typealias WebSocketStream = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>

final class WebSocket: NSObject, @unchecked Sendable, Loggable, AsyncSequence, URLSessionWebSocketDelegate {
    typealias AsyncIterator = WebSocketStream.Iterator
    typealias Element = URLSessionWebSocketTask.Message

    private let _state = StateSync(State())

    private struct State {
        var streamContinuation: WebSocketStream.Continuation?
        var connectContinuation: CheckedContinuation<Void, Error>?
    }

    private let request: URLRequest

    private lazy var urlSession: URLSession = {
        #if targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            nw_tls_create_options()
        }
        #endif
        let config = URLSessionConfiguration.default
        // explicitly set timeout intervals
        config.timeoutIntervalForRequest = TimeInterval(60)
        config.timeoutIntervalForResource = TimeInterval(604_800)
        config.shouldUseExtendedBackgroundIdleMode = true
        config.networkServiceType = .callSignaling
        #if os(iOS) || os(visionOS)
        /// https://developer.apple.com/documentation/foundation/urlsessionconfiguration/improving_network_reliability_using_multipath_tcp
        config.multipathServiceType = .handover
        #endif
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private lazy var task: URLSessionWebSocketTask = urlSession.webSocketTask(with: request)

    private lazy var stream: WebSocketStream = WebSocketStream { continuation in
        _state.mutate { state in
            state.streamContinuation = continuation
        }
        waitForNextValue()
    }

    init(url: URL, connectOptions: ConnectOptions?) async throws {
        request = URLRequest(url: url,
                             cachePolicy: .useProtocolCachePolicy,
                             timeoutInterval: connectOptions?.socketConnectTimeoutInterval ?? .defaultSocketConnect)
        super.init()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                _state.mutate { state in
                    state.connectContinuation = continuation
                }
                task.resume()
            }
        } onCancel: {
            // Cancel(reset) when Task gets cancelled
            close()
        }
    }

    deinit {
        close()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        urlSession.finishTasksAndInvalidate()

        _state.mutate { state in
            state.connectContinuation?.resume(throwing: LiveKitError(.cancelled))
            state.connectContinuation = nil
            state.streamContinuation?.finish(throwing: LiveKitError(.cancelled))
            state.streamContinuation = nil
        }
    }

    // MARK: - AsyncSequence

    func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }

    private func waitForNextValue() {
        guard task.closeCode == .invalid else {
            _state.mutate { state in
                state.streamContinuation?.finish(throwing: LiveKitError(.invalidState))
                state.streamContinuation = nil
            }
            return
        }

        task.receive(completionHandler: { [weak self] result in
            guard let self, let continuation = _state.streamContinuation else {
                return
            }

            do {
                let message = try result.get()
                continuation.yield(message)
                waitForNextValue()
            } catch {
                _state.mutate { state in
                    state.streamContinuation?.finish(throwing: LiveKitError.from(error: error))
                    state.streamContinuation = nil
                }
            }
        })
    }

    // MARK: - Send

    func send(data: Data) async throws {
        let message = URLSessionWebSocketTask.Message.data(data)
        try await task.send(message)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        _state.mutate { state in
            state.connectContinuation?.resume()
            state.connectContinuation = nil
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        log("didCompleteWithError: \(String(describing: error))", error != nil ? .error : .debug)

        _state.mutate { state in
            if let error {
                let lkError = LiveKitError.from(error: error) ?? LiveKitError(.unknown)
                state.connectContinuation?.resume(throwing: lkError)
                state.streamContinuation?.finish(throwing: lkError)
            } else {
                state.connectContinuation?.resume()
                state.streamContinuation?.finish()
            }

            state.connectContinuation = nil
            state.streamContinuation = nil
        }
    }
}
