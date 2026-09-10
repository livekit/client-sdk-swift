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

internal import LiveKitUniFFI
import Foundation

/// Registers the SDK's own network stack as `livekit-net`'s transport, so anything the
/// Rust side sends goes out over the same ``WebSocket``/``HTTP`` session the Swift path
/// uses — one place tuning `networkServiceType`, multipath, TLS workarounds and logging.
///
/// Lazily initialized on first access, like ``sharedLogger``: `livekit-net` keeps its
/// clients in a `OnceLock`, so this runs once and later accesses are free.
let rustTransport: Void = {
    setWsClient(client: WsClientAdapter())
    setHttpClient(client: HttpClientAdapter())
}()

// MARK: - WebSocket

final class WsClientAdapter: WsClient {
    func connect(url: String, headers: [Header], timeoutMs: UInt64) async throws -> WsConnectResult {
        guard let url = URL(string: url) else {
            throw TransportError.Other("invalid url: \(url)")
        }
        do {
            let socket = try await WebSocket(url: url,
                                             headers: headers.asDictionary,
                                             timeoutInterval: TimeInterval(timeoutMs) / 1000)
            return WsConnectResult(connection: WsConnectionAdapter(socket))
        } catch {
            throw error.asTransportError
        }
    }
}

private final class WsConnectionAdapter: WsConnection {
    private let socket: WebSocket

    init(_ socket: WebSocket) {
        self.socket = socket
    }

    func send(frame: Data) async throws {
        do {
            try await socket.send(data: frame)
        } catch {
            throw error.asTransportError
        }
    }

    func recv() async throws -> Data? {
        do {
            // Signalling is binary-only, so `for case let` skips any other frame kind and
            // keeps reading. Iterating afresh per call is the same stream: the iterator
            // buffers nothing, it reads straight off the task.
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

// MARK: - HTTP

final class HttpClientAdapter: HttpClient {
    /// Translate one `livekit-net` HTTP call into a `URLRequest`. Cache policy and timeout
    /// belong to ``HTTP/request(_:cachePolicy:timeoutInterval:)``, not here.
    static func makeRequest(method: HttpMethod, url: URL, headers: [Header], body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = switch method {
        case .get: "GET"
        case .post: "POST"
        }
        request.httpBody = body
        for header in headers {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    func request(method: HttpMethod, url: String, headers: [Header], body: Data?) async throws -> HttpResponse {
        guard let url = URL(string: url) else {
            throw TransportError.Other("invalid url: \(url)")
        }
        do {
            // A 4xx/5xx is a response, not a transport failure — only the transport throws.
            let request = Self.makeRequest(method: method, url: url, headers: headers, body: body)
            let (data, response) = try await HTTP.request(request)
            return HttpResponse(status: UInt16(clamping: response.statusCode),
                                headers: response.headers,
                                body: data)
        } catch {
            throw error.asTransportError
        }
    }
}

// MARK: - Conversions

private extension [Header] {
    var asDictionary: [String: String] {
        reduce(into: [:]) { $0[$1.name] = $1.value }
    }
}

private extension HTTPURLResponse {
    /// - Note: `livekit-net` documents receipt order, which `HTTPURLResponse` does not keep.
    var headers: [Header] {
        allHeaderFields.compactMap { name, value in
            guard let name = name as? String else { return nil }
            return Header(name: name, value: String(describing: value))
        }
    }
}

extension Error {
    /// Map onto `livekit-net`'s taxonomy, which the Rust signal client branches on:
    /// `Http` is a rejected upgrade (fail fast), `Timeout`/`Closed`/`Connection` all
    /// drive a reconnect.
    var asTransportError: TransportError {
        if let transportError = self as? TransportError { return transportError }

        let underlying = (self as? LiveKitError)?.internalError ?? self

        if let upgrade = underlying as? WebSocketUpgradeFailure {
            return .Http(status: UInt16(clamping: upgrade.statusCode))
        }
        if let urlError = underlying as? URLError {
            switch urlError.code {
            case .timedOut:
                return .Timeout
            // Our own `close()` surfaces as `.cancelled`; a peer reset arrives as
            // `.networkConnectionLost`. Both are end-of-stream to livekit-net.
            case .cancelled, .networkConnectionLost:
                return .Closed
            default:
                // The numeric code, not `localizedDescription`: this string is what Rust
                // logs and what gets grepped and grouped, and it must not change with the
                // device's language.
                return .Connection("URLError \(urlError.errorCode)")
            }
        }
        let nsError = underlying as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(ECONNRESET) || nsError.code == Int(ENOTCONN)
        {
            return .Closed
        }
        if let type = (self as? LiveKitError)?.type {
            switch type {
            case .timedOut: return .Timeout
            case .cancelled: return .Closed
            default: break
            }
        }
        return .Connection(String(describing: underlying))
    }
}
