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
        var request = try URLRequest(url: requestURL(url, schemes: ["ws", "wss"]))
        let timeout = Double(timeoutMs) / 1000
        request.timeoutInterval = timeout
        for header in headers {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        let connection = NativeWebSocketConnection(request: request)
        let deadline = DispatchWorkItem { [weak connection] in
            guard let connection else { return }
            connection.opened.resolve(.failure(TransportError.Timeout))
            connection.cancel()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            connection.task.resume()
            do {
                try await connection.opened.value()
                try Task.checkCancellation()
                return WsConnectResult(connection: connection)
            } catch {
                connection.cancel()
                throw transportError(error)
            }
        } onCancel: {
            connection.opened.resolve(.failure(TransportError.Closed))
            connection.cancel()
        }
    }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    let opened = Completion<Void>()

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        opened.resolve(.success(()))
    }

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask,
                    didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?)
    {
        opened.resolve(.failure(TransportError.Closed))
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            opened.resolve(.failure(TransportError.Http(status: UInt16(response.statusCode))))
            return
        }
        opened.resolve(.failure(error.map(transportError) ?? .Closed))
    }
}

// Immutable references to Foundation's thread-safe task/session. Rust sends and receives
// concurrently; close/cancellation must wake a pending receive without waiting for it.
private final class NativeWebSocketConnection: WsConnection {
    let task: URLSessionWebSocketTask
    let opened: Completion<Void>
    private let session: URLSession

    init(request: URLRequest) {
        let delegate = WebSocketDelegate()
        opened = delegate.opened
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request)
    }

    deinit { session.invalidateAndCancel() }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    func send(frame: Data) async throws {
        let completion = Completion<Void>()
        try await withTaskCancellationHandler {
            task.send(.data(frame)) { error in
                completion.resolve(error.map { .failure(transportError($0)) } ?? .success(()))
            }
            try await completion.value()
        } onCancel: {
            cancel()
            completion.resolve(.failure(TransportError.Closed))
        }
    }

    func recv() async throws -> Data? {
        try await withTaskCancellationHandler {
            while true {
                if Task.isCancelled { throw TransportError.Closed }
                do {
                    let message = try await withCheckedThrowingContinuation { continuation in
                        task.receive { continuation.resume(with: $0) }
                    }
                    if case let .data(data) = message { return data }
                    // Signaling consumes binary frames only; Foundation handles control frames.
                } catch {
                    if task.closeCode != .invalid { return nil }
                    throw transportError(error)
                }
            }
        } onCancel: { cancel() }
    }

    func close() async {
        // Closing never waits for the peer; cancellation aborts the close handshake.
        await withTaskCancellationHandler {
            task.cancel(with: .normalClosure, reason: nil)
            session.finishTasksAndInvalidate()
        } onCancel: { cancel() }
    }
}
