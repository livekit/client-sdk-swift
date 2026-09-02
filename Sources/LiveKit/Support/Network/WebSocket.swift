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

actor WebSocket: Loggable, AsyncSequence {
    typealias Element = URLSessionWebSocketTask.Message

    private let delegate: Delegate
    private let urlSession: URLSession
    private let task: URLSessionWebSocketTask

    private static func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 604_800
        config.shouldUseExtendedBackgroundIdleMode = true
        config.networkServiceType = .callSignaling
        #if os(iOS) || os(visionOS)
        // https://developer.apple.com/documentation/foundation/urlsessionconfiguration/improving_network_reliability_using_multipath_tcp
        config.multipathServiceType = .handover
        #endif
        return config
    }

    init(url: URL, headers: [String: String], timeoutInterval: TimeInterval) async throws {
        var request = URLRequest(url: url,
                                 cachePolicy: .useProtocolCachePolicy,
                                 timeoutInterval: timeoutInterval)
        for (name, value) in headers {
            request.addValue(value, forHTTPHeaderField: name)
        }

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

        func next() async throws -> URLSessionWebSocketTask.Message? {
            guard task.closeCode == .invalid else { return nil }
            return try await withTaskCancellationHandler {
                do {
                    // Use the callback API instead of the async overlay to avoid
                    // a TSan-visible data race inside Foundation's continuation bridge.
                    return try await withCheckedThrowingContinuation { continuation in
                        task.receive { result in
                            continuation.resume(with: result)
                        }
                    }
                } catch {
                    // On clean shutdown, task.receive() throws URLError(.cancelled)
                    // rather than CancellationError. Return nil (end-of-sequence)
                    // instead of propagating, so `subscribe` doesn't call onFailure.
                    if task.closeCode != .invalid || Task.isCancelled { return nil }
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

    // MARK: - Delegate

    private final class Delegate: NSObject, Loggable, URLSessionWebSocketDelegate {
        private let _continuation = StateSync<CheckedContinuation<Void, Error>?>(nil)

        func setConnectContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            _continuation.mutate { $0 = continuation }
        }

        func cancelConnection() {
            _continuation.mutate {
                $0?.resume(throwing: LiveKitError(.cancelled))
                $0 = nil
            }
        }

        func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
            _continuation.mutate {
                $0?.resume()
                $0 = nil
            }
        }

        func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            log("didCompleteWithError: \(String(describing: error))", error != nil ? .error : .debug)

            // A rejected upgrade (401 on a bad token, 404 on a wrong path) arrives as a
            // plain URLError with the HTTP response still attached. Keep the status: it is
            // the difference between failing fast and reconnecting forever.
            let upgradeStatus = (task.response as? HTTPURLResponse)
                .map(\.statusCode)
                .flatMap { $0 == 101 ? nil : WebSocketUpgradeFailure(statusCode: $0) }

            _continuation.mutate {
                if let upgradeStatus {
                    $0?.resume(throwing: LiveKitError(.network, internalError: upgradeStatus))
                } else if let error {
                    $0?.resume(throwing: LiveKitError.from(error: error) ?? LiveKitError(.unknown))
                } else {
                    $0?.resume()
                }
                $0 = nil
            }
        }
    }
}
