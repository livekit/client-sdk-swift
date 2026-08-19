// Copyright 2026 LiveKit (Apache-2.0)
import Foundation
import Testing
@testable import LiveKit
import LiveKitUniFFI

// Serialized: the DEBUG delegate seam is process-global mutable state; Swift Testing
// runs @Tests in parallel, so these must not run concurrently with each other.
@Suite(.serialized)
struct NetFFIRoundTripTests {
    private final class DummyHTTP: HttpClient, @unchecked Sendable {
        func request(method: HttpMethod, url: String, headers: [Header], body: Data?) async throws -> HttpResponse {
            HttpResponse(status: 201, headers: [Header(name: "x-test", value: "1")], body: Data("hello".utf8))
        }
    }
    private final class DummyConn: WsConnection, @unchecked Sendable {
        private let store = StateSync<Data?>(nil)
        func send(frame: Data) async throws { store.mutate { $0 = frame } }
        func recv() async throws -> Data? { store.mutate { let f = $0; $0 = nil; return f } }
        func close() async {}
    }
    private final class DummyWS: WsClient, @unchecked Sendable {
        func connect(url: String, headers: [Header], timeoutMs: UInt64) async throws -> WsConnectResult {
            WsConnectResult(connection: DummyConn())
        }
    }

    @Test func httpGetRoundTripsThroughFFI() async throws {
        _ = LKNet.bootstrap
        LKNet.httpClient.setDelegate(DummyHTTP())
        defer { LKNet.httpClient.setDelegate(LKNetHTTPClientLive()) }

        let resp = try await selfTestHttpGet(url: "http://example.test/x")
        #expect(resp.status == 201)
        #expect(resp.body == Data("hello".utf8))
        #expect(resp.headers.contains { $0.name == "x-test" && $0.value == "1" })
    }

    @Test func wsEchoRoundTripsThroughFFI() async throws {
        _ = LKNet.bootstrap
        LKNet.wsClient.setDelegate(DummyWS())
        defer { LKNet.wsClient.setDelegate(LKNetWSClientLive()) }

        let echoed = try await selfTestWsEcho(url: "ws://example.test/x", payload: Data("ping".utf8))
        #expect(echoed == Data("ping".utf8))
    }
}
