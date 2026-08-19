// Copyright 2026 LiveKit (Apache-2.0)
import Foundation
internal import LiveKitUniFFI

/// Live HTTP transport backing `livekit-net`, over `URLSession`. Byte-faithful:
/// returns raw response bytes; never decodes to string/JSON.
final class LKNetHTTPClientLive: HttpClient, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    func request(method: HttpMethod, url: String, headers: [Header], body: Data?) async throws -> HttpResponse {
        guard let u = URL(string: url) else { throw TransportError.Connection("invalid url: \(url)") }
        var req = URLRequest(url: u)
        req.httpMethod = method == .get ? "GET" : "POST"
        for h in headers { req.addValue(h.value, forHTTPHeaderField: h.name) }
        if let body { req.httpBody = body }

        do {
            let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
                let task = session.dataTask(with: req) { data, response, error in
                    if let error { cont.resume(throwing: error) }
                    else if let data, let response { cont.resume(returning: (data, response)) }
                    else { cont.resume(throwing: URLError(.badServerResponse)) }
                }
                task.resume()
            }
            guard let http = response as? HTTPURLResponse else {
                throw TransportError.Other("non-HTTP response")
            }
            let respHeaders: [Header] = http.allHeaderFields.compactMap { key, value in
                guard let name = key as? String else { return nil }
                return Header(name: name, value: "\(value)")
            }
            return HttpResponse(status: UInt16(clamping: http.statusCode), headers: respHeaders, body: data)
        } catch let t as TransportError {
            throw t
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw TransportError.Timeout
            case .cancelled: throw TransportError.Closed
            default: throw TransportError.Connection(e.localizedDescription)
            }
        } catch {
            throw TransportError.Connection("\(error)")
        }
    }
}

/// Forwarding HTTP client registered with `livekit-net`. Production forwards to
/// `LKNetHTTPClientLive`; `#if DEBUG` tests swap the delegate to a dummy.
final class LKNetHTTPClient: HttpClient, @unchecked Sendable {
    private let delegate: StateSync<any HttpClient>

    init(_ initial: any HttpClient = LKNetHTTPClientLive()) {
        delegate = StateSync(initial)
    }

    #if DEBUG
    func setDelegate(_ d: any HttpClient) { delegate.mutate { $0 = d } }
    #endif

    func request(method: HttpMethod, url: String, headers: [Header], body: Data?) async throws -> HttpResponse {
        try await delegate.read { $0 }.request(method: method, url: url, headers: headers, body: body)
    }
}
