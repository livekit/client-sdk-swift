// Copyright 2026 LiveKit (Apache-2.0)
import Foundation
import Testing
@testable import LiveKit
import LiveKitUniFFI

// Uses a dedicated, file-private URLProtocol (not the shared LiveKitTestSupport
// `MockURLProtocol`) so this suite's process-global mock state cannot be reset by
// another suite that also uses `MockURLProtocol` (e.g. `RegionManagerTests`) when
// Swift Testing runs suites in parallel. `.serialized` keeps this suite's own tests
// from racing each other on that state.
@Suite(.serialized)
struct LKNetHTTPClientLiveTests {
    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LKNetMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func getMapsResponse() async throws {
        LKNetMockURLProtocol.reset()
        defer { LKNetMockURLProtocol.reset() }
        LKNetMockURLProtocol.setRequestHandler { req in
            #expect(req.httpMethod == "GET")
            #expect(req.value(forHTTPHeaderField: "x-req") == "1")
            return .init(statusCode: 201, headers: ["x-test": "yes"], body: Data("hi".utf8))
        }
        let client = LKNetHTTPClientLive(session: mockSession())
        let resp = try await client.request(method: .get, url: "https://example.test/status",
                                            headers: [Header(name: "x-req", value: "1")], body: nil)
        #expect(resp.status == 201)
        #expect(resp.body == Data("hi".utf8))
        #expect(resp.headers.contains { $0.name.lowercased() == "x-test" && $0.value == "yes" })
    }

    @Test func timeoutMapsToTransportTimeout() async throws {
        LKNetMockURLProtocol.reset()
        defer { LKNetMockURLProtocol.reset() }
        LKNetMockURLProtocol.setRequestHandler { _ in throw URLError(.timedOut) }
        let client = LKNetHTTPClientLive(session: mockSession())
        await #expect(throws: TransportError.self) {
            _ = try await client.request(method: .get, url: "https://example.test/slow", headers: [], body: nil)
        }
    }

    @Test func forwardingDelegatesToInner() async throws {
        LKNetMockURLProtocol.reset()
        defer { LKNetMockURLProtocol.reset() }
        LKNetMockURLProtocol.setRequestHandler { _ in .init(statusCode: 200, headers: [:], body: Data()) }
        let fwd = LKNetHTTPClient(LKNetHTTPClientLive(session: mockSession()))
        let resp = try await fwd.request(method: .get, url: "https://example.test/f", headers: [], body: nil)
        #expect(resp.status == 200)
    }
}

/// Isolated `URLProtocol` for `LKNetHTTPClientLiveTests` only. Its state is process
/// global (as all `URLProtocol` state must be), but no other suite references this
/// class, so it cannot be reset mid-request by a parallel suite. Attached solely via
/// the ephemeral session's `protocolClasses`, so it never intercepts other traffic.
private final class LKNetMockURLProtocol: URLProtocol {
    struct Response: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private struct State {
        var requestHandler: (@Sendable (URLRequest) throws -> Response)?
    }

    private static let _state = StateSync(State())

    static func setRequestHandler(_ handler: (@Sendable (URLRequest) throws -> Response)?) {
        _state.mutate { $0.requestHandler = handler }
    }

    static func reset() {
        _state.mutate { $0.requestHandler = nil }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self._state.read({ $0.requestHandler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let mock = try handler(request)
            guard let response = HTTPURLResponse(url: url,
                                                 statusCode: mock.statusCode,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: mock.headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: mock.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
