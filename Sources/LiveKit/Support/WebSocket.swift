/*
 * Copyright 2022-2023 LiveKit
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

internal typealias WebSocketStream = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>

internal class WebSocket: NSObject, Loggable, AsyncSequence, URLSessionWebSocketDelegate {

    typealias AsyncIterator = WebSocketStream.Iterator
    typealias Element = URLSessionWebSocketTask.Message

    private var streamContinuation: WebSocketStream.Continuation?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    private let request: URLRequest

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        // explicitly set timeout intervals
        config.timeoutIntervalForRequest = TimeInterval(60)
        config.timeoutIntervalForResource = TimeInterval(604_800)
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private lazy var task: URLSessionWebSocketTask = {
        urlSession.webSocketTask(with: request)
    }()

    private lazy var stream: WebSocketStream = {
        return WebSocketStream { continuation in
            streamContinuation = continuation
            waitForNextValue()
        }
    }()

    init(url: URL) {

        request = URLRequest(url: url,
                             cachePolicy: .useProtocolCachePolicy,
                             timeoutInterval: .defaultSocketConnect)
    }

    deinit {
        reset()
    }

    public func connect() async throws {

        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            task.resume()
        }
    }

    func reset() {
        task.cancel(with: .goingAway, reason: nil)
        connectContinuation?.resume(throwing: SignalClientError.socketError(rawError: nil))
        connectContinuation = nil
        streamContinuation?.finish()
        streamContinuation = nil
    }

    // MARK: - AsyncSequence

    func makeAsyncIterator() -> AsyncIterator {
        return stream.makeAsyncIterator()
    }

    private func waitForNextValue() {
        guard task.closeCode == .invalid else {
            streamContinuation?.finish()
            streamContinuation = nil
            return
        }

        task.receive(completionHandler: { [weak self] result in
            guard let continuation = self?.streamContinuation else {
                return
            }

            do {
                let message = try result.get()
                continuation.yield(message)
                self?.waitForNextValue()
            } catch {
                continuation.finish(throwing: error)
                self?.streamContinuation = nil
            }
        })
    }

    // MARK: - Send

    public func send(data: Data) async throws {
        let message = URLSessionWebSocketTask.Message.data(data)
        try await task.send(message)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        log("didCompleteWithError: \(String(describing: error))", .error)
        let error = error ??  NetworkError.disconnected(message: "WebSocket didCompleteWithError")
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        streamContinuation?.finish()
        streamContinuation = nil
    }
}
