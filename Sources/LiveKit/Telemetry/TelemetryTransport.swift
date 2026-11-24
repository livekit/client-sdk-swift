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

internal import LiveKitFFI
import Foundation

// MARK: - Transport

/// Moves the core's requests: status, headers and body go back untouched and the core decides
/// what they mean. Only a missing answer is an error.
final class URLSessionTelemetryTransport: TelemetryTransport {
    /// Ephemeral (no cookies, no cache), and never follows a redirect to another origin: the
    /// request carries the participant token.
    static let defaultSession = URLSession(configuration: .ephemeral, delegate: SameOriginRedirects(), delegateQueue: nil)

    /// Reads every answer of this transport; owned by `session`, which this transport owns.
    let reader = BoundedReader(limit: URLSessionTelemetryTransport.maxResponseBytes)
    private let session: URLSession

    /// `session` gives the configuration only: requests run on a session of this transport's own,
    /// whose delegate bounds every answer while it is read, on every OS.
    init(session: URLSession = URLSessionTelemetryTransport.defaultSession) {
        self.session = URLSession(configuration: session.configuration, delegate: reader, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate() // the session lets go of `reader` once its reads end
    }

    func send(request: ExportRequest) async throws -> ExportResponse {
        guard let url = URL(string: request.url) else {
            throw ExportError.Rejected(reason: "invalid url \(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await reader.read(urlRequest, on: session)
        } catch {
            throw ExportError.Retryable(reason: error.localizedDescription, retryAfterMs: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ExportError.Retryable(reason: "not an HTTP response", retryAfterMs: nil)
        }
        var headers: [String: String] = [:]
        for case let (name as String, value as String) in http.allHeaderFields {
            headers[name] = value
        }
        return ExportResponse(status: UInt16(clamping: http.statusCode), headers: headers, body: data)
    }

    /// The core's limit on a collector answer, in decoded bytes.
    static let maxResponseBytes = 65536
}

/// Reads answers as they arrive, on every OS: keeps at most `limit` + 1 decoded bytes, then
/// cancels the task, so the core sees a longer body as an overflow and retries the batch,
/// `Retry-After` included. Redirects as ``SameOriginRedirects``. Each read stays registered by
/// its task until its one answer is delivered.
final class BoundedReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Read {
        var response: URLResponse?
        var body = Data()
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        /// The answer of a task that ended before its read registered (cancelled that early).
        var result: Result<(Data, URLResponse), Error>?
    }

    let limit: Int
    private let reads = StateSync([Int: Read]())

    init(limit: Int) {
        self.limit = limit
    }

    /// Tasks with state here: none once every answer is delivered.
    var pending: Int { reads.read { $0.count } }

    func read(_ request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        let id = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early: Result<(Data, URLResponse), Error>? = reads.mutate { reads in
                    if let result = reads[id]?.result {
                        reads[id] = nil
                        return result
                    }
                    reads[id, default: Read()].continuation = continuation
                    return nil
                }
                if let early { continuation.resume(with: early) } else { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        reads.mutate { $0[dataTask.taskIdentifier, default: Read()].response = response }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        let over = reads.mutate { reads in
            let room = max(0, limit + 1 - (reads[id]?.body.count ?? 0))
            reads[id, default: Read()].body.append(data.prefix(room))
            return (reads[id]?.body.count ?? 0) > limit
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let (continuation, result) = reads.mutate { reads in
            let read = reads[id] ?? Read()
            let result: Result<(Data, URLResponse), Error> = if let response = read.response, error == nil || read.body.count > limit {
                .success((read.body, response)) // an overflow ends in our own cancel: still an answer
            } else {
                .failure(error ?? URLError(.badServerResponse))
            }
            guard let continuation = read.continuation else {
                reads[id] = Read(result: result) // `read` picks it up when it registers
                return (CheckedContinuation<(Data, URLResponse), Error>?.none, result)
            }
            reads[id] = nil
            return (continuation, result)
        }
        continuation?.resume(with: result)
    }

    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(SameOriginRedirects.follows(request, of: task) ? request : nil)
    }
}

/// A redirect to another scheme, host or port is not followed: the 3xx comes back as the answer.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static func follows(_ request: URLRequest, of task: URLSessionTask) -> Bool {
        let from = task.originalRequest?.url, to = request.url
        return from?.scheme == to?.scheme && from?.host == to?.host && from?.port == to?.port
    }

    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(Self.follows(request, of: task) ? request : nil)
    }
}
