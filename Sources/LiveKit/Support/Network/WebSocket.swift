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

actor WebSocket: Loggable, AsyncSequence {
    typealias Element = URLSessionWebSocketTask.Message

    private let delegate: Delegate
    private let urlSession: URLSession
    private let task: URLSessionWebSocketTask

    private static func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(60)
        config.timeoutIntervalForResource = TimeInterval(604_800)
        config.shouldUseExtendedBackgroundIdleMode = true
        config.networkServiceType = .callSignaling
        #if os(iOS) || os(visionOS)
        /// https://developer.apple.com/documentation/foundation/urlsessionconfiguration/improving_network_reliability_using_multipath_tcp
        config.multipathServiceType = .handover
        #endif
        return config
    }

    init(url: URL, token: String, connectOptions: ConnectOptions?) async throws {
        var request = URLRequest(url: url,
                                 cachePolicy: .useProtocolCachePolicy,
                                 timeoutInterval: connectOptions?.socketConnectTimeoutInterval ?? .defaultSocketConnect)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        #if targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            nw_tls_create_options()
        }
        #endif

        delegate = Delegate()
        urlSession = URLSession(configuration: Self.makeSessionConfiguration(),
                                delegate: delegate, delegateQueue: nil)
        task = urlSession.webSocketTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setConnectContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            self.close()
        }
    }

    deinit {
        close()
    }

    nonisolated func close() {
        task.cancel(with: .normalClosure, reason: nil)
        urlSession.finishTasksAndInvalidate()
        delegate.cancelConnection()
    }

    // MARK: - AsyncSequence

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let task: URLSessionWebSocketTask

        mutating func next() async throws -> URLSessionWebSocketTask.Message? {
            let task = task
            guard task.closeCode == .invalid else { return nil }
            return try await withTaskCancellationHandler {
                do {
                    return try await task.receive()
                } catch {
                    throw LiveKitError.from(error: error) ?? error
                }
            } onCancel: {
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(task: task)
    }

    // MARK: - Send

    nonisolated func send(data: Data) async throws {
        try await task.send(.data(data))
    }

    // MARK: - URLSessionWebSocketDelegate

    private final class Delegate: NSObject, Loggable, URLSessionWebSocketDelegate {
        private let _state = StateSync(State())

        private struct State {
            var connectContinuation: CheckedContinuation<Void, Error>?
        }

        func setConnectContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            _state.mutate { $0.connectContinuation = continuation }
        }

        func cancelConnection() {
            _state.mutate { state in
                state.connectContinuation?.resume(throwing: LiveKitError(.cancelled))
                state.connectContinuation = nil
            }
        }

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
                } else {
                    state.connectContinuation?.resume()
                }

                state.connectContinuation = nil
            }
        }
    }
}
