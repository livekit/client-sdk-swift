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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import LiveKitUniFFI

/// Drives the registered transport from the Rust side, through the FFI, using
/// `livekit-net`'s own `self_test_*` exports — the same entry points the Rust
/// crate's `native_parity` suite uses against its bundled client. Nothing here
/// reaches into the adapter directly, so what is under test is the whole seam.
///
/// Requires a local `livekit-server` (see AGENTS.md).
@Suite(.tags(.e2e, .networking))
struct RustTransportTests {
    private let httpUrl: String
    private let wsUrl: String

    init() {
        // `Room.init` forces this too; it runs once per process.
        _ = rustTransport
        wsUrl = TestEnvironment.liveKitServerUrl()
        httpUrl = wsUrl
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
    }

    @Test("Both clients are registered")
    func registersBothClients() {
        #expect(hasHttpClient())
        #expect(hasWsClient())
    }

    @Test("A GET crosses the FFI and comes back whole")
    func httpGetRoundTrips() async throws {
        let response = try await selfTestHttpGet(url: httpUrl)

        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8) == "OK")
        // Headers are what let the Rust side read Cache-Control, so prove they survive.
        #expect(!response.headers.isEmpty)
    }

    @Test("An error status is a response, not a transport failure")
    func errorStatusIsAResponse() async throws {
        let response = try await selfTestHttpGet(url: "\(httpUrl)/no-such-endpoint")

        #expect(response.status == 404)
    }

    /// The one mapping the Rust signal client branches on: `TransportError::Http`
    /// becomes `SignalError::Handshake { status }` and fails fast, where a plain
    /// `Connection` would drive an endless reconnect loop.
    @Test("A rejected upgrade keeps its HTTP status")
    func rejectedUpgradeKeepsItsStatus() async throws {
        // No token on the signalling socket, so the server refuses the upgrade.
        await #expect(throws: TransportError.Http(status: 401)) {
            try await selfTestWsEcho(url: "\(wsUrl)/rtc", payload: Data([0x01]))
        }
    }

    /// `livekit-server` pushes a `JoinResponse` straight after the upgrade, so it is a
    /// real peer that talks back: `self_test_ws_echo` connects, sends, receives one frame
    /// and closes, all through the registered Swift transport.
    @Test("A signalling socket connects, sends, receives and closes")
    func webSocketRoundTrips() async throws {
        let room = "rust-transport-\(UUID().uuidString)"
        let token = try TestEnvironment.liveKitServerToken(for: room, identity: "rust-transport")
        var components = try #require(URLComponents(string: "\(wsUrl)/rtc"))
        components.queryItems = [URLQueryItem(name: "access_token", value: token),
                                 URLQueryItem(name: "protocol", value: "15")]
        let ping = try Livekit_SignalRequest.with { $0.ping = 1 }.serializedData()

        let frame = try await selfTestWsEcho(url: #require(components.string), payload: ping)

        let response = try Livekit_SignalResponse(serializedBytes: frame)
        #expect(response.join.room.name == room)
    }

    /// livekit-net's `recv` contract: `Ok(None)` for a gone peer, never an error. The
    /// Rust read loop uses it to tell a clean teardown from a failure.
    @Test("recv reports end-of-stream once the socket is closed")
    func recvReportsEndOfStream() async throws {
        let token = try TestEnvironment.liveKitServerToken(for: "rust-transport-eof", identity: "rust-transport")
        let connection = try await WsClientAdapter()
            .connect(url: "\(wsUrl)/rtc?protocol=15",
                     headers: [Header(name: "Authorization", value: "Bearer \(token)")],
                     timeoutMs: 10000)
            .connection

        await connection.close()

        #expect(try await connection.recv() == nil)
    }

    /// A `TransportError` thrown in Swift has to reach Rust as the same variant *with*
    /// its payload. `.Http` and `.Connection` are pinned by the tests above; this pins
    /// the string-carrying case, which is the one that can silently arrive empty.
    @Test("A thrown TransportError keeps its payload across the FFI")
    func thrownErrorKeepsItsPayload() async throws {
        let error = await #expect(throws: TransportError.self) {
            // Foundation percent-encodes most junk, so an empty string is the
            // reliable way to fail `URL(string:)`.
            try await selfTestHttpGet(url: "")
        }

        guard case let .Other(message) = error else {
            Issue.record("expected .Other, got \(String(describing: error))")
            return
        }
        #expect(message.contains("invalid url"))
    }

    /// A Swift-owned socket and a Rust-owned one to the same endpoint must not share
    /// anything. Each ``WebSocket`` builds its own `URLSession`, so closing one calls
    /// `finishTasksAndInvalidate()` on that session alone — pooling sessions (which Apple
    /// otherwise recommends) would make the Rust socket's teardown kill the Swift one.
    @Test("A Swift socket survives a Rust socket's whole lifecycle on the same URL")
    func swiftAndRustSocketsAreIndependent() async throws {
        let room = "rust-transport-\(UUID().uuidString)"
        let rtcUrl = "\(wsUrl)/rtc?protocol=15"

        // Distinct identities: the same one twice is a duplicate join, and the server
        // would evict one socket for us and hide the thing under test.
        let swiftToken = try TestEnvironment.liveKitServerToken(for: room, identity: "swift-reader")
        let swiftSocket = try await WebSocket(url: #require(URL(string: rtcUrl)),
                                              headers: ["Authorization": "Bearer \(swiftToken)"],
                                              timeoutInterval: 10)
        defer { swiftSocket.close() }
        var frames = swiftSocket.makeAsyncIterator()
        #expect(try await joinedRoom(in: frames.next()) == room)

        let rustToken = try TestEnvironment.liveKitServerToken(for: room, identity: "rust-reader")
        var components = try #require(URLComponents(string: "\(wsUrl)/rtc"))
        components.queryItems = [URLQueryItem(name: "access_token", value: rustToken),
                                 URLQueryItem(name: "protocol", value: "15")]
        // Connects, sends, receives and closes — the close is what would take the
        // Swift socket down with it if the two shared a session.
        let rustFrame = try await selfTestWsEcho(url: #require(components.string),
                                                 payload: Livekit_SignalRequest.with { $0.ping = 1 }.serializedData())
        #expect(try Livekit_SignalResponse(serializedBytes: rustFrame).join.room.name == room)

        // The Swift socket still round-trips. `pingReq`, not the bare `ping`: only the
        // former is answered by a current server (SignalClient sends both, for old ones).
        let timestamp = Int64(2)
        try await swiftSocket.send(data: Livekit_SignalRequest.with {
            $0.pingReq = Livekit_Ping.with { $0.timestamp = timestamp }
        }.serializedData())

        var sawPong = false
        while !sawPong, let frame = try await frames.next() {
            guard case let .data(data) = frame else { continue }
            let response = try Livekit_SignalResponse(serializedBytes: data)
            sawPong = response.pongResp.lastPingTimestamp == timestamp || response.pong == timestamp
        }
        #expect(sawPong)
    }

    /// The room a JOIN frame names. `#require` rather than an optional return, so a text
    /// or absent frame reports itself instead of failing an unrelated equality.
    private func joinedRoom(in message: URLSessionWebSocketTask.Message?) throws -> String {
        guard case let .data(data) = try #require(message) else {
            throw LiveKitError(.invalidState, message: "expected a binary frame, got \(message!)")
        }
        return try Livekit_SignalResponse(serializedBytes: data).join.room.name
    }

    @Test("An unreachable peer is a connection error")
    func unreachablePeerIsAConnectionError() async throws {
        let error = await #expect(throws: TransportError.self) {
            // Port 1 is reserved and never listening.
            try await selfTestHttpGet(url: "http://127.0.0.1:1/")
        }

        guard case let .Connection(message) = error else {
            Issue.record("expected .Connection, got \(String(describing: error))")
            return
        }
        // The URLError code is kept, not the device-localized description.
        #expect(message.contains("URLError"))
    }
}

/// The mapping the whole seam hinges on, exercised where a socket cannot reach it:
/// `ECONNRESET` mid-frame and a bare `URLError(.timedOut)` are not things a healthy
/// `livekit-server` will produce on demand.
@Suite(.tags(.networking))
struct TransportErrorMappingTests {
    @Test("Errors map onto livekit-net's taxonomy", arguments: [
        // A rejected upgrade keeps its status, bare or wrapped by the WebSocket delegate.
        (WebSocketUpgradeFailure(statusCode: 401), TransportError.Http(status: 401)),
        (LiveKitError(.network, internalError: WebSocketUpgradeFailure(statusCode: 503)), .Http(status: 503)),
        (URLError(.timedOut), .Timeout),
        (LiveKitError(.timedOut), .Timeout),
        // Every abrupt teardown livekit-net folds into end-of-stream.
        (URLError(.cancelled), .Closed),
        (URLError(.networkConnectionLost), .Closed),
        (POSIXError(.ECONNRESET), .Closed),
        (POSIXError(.ENOTCONN), .Closed),
        (LiveKitError(.cancelled), .Closed),
        // Already ours: crossing the FFI twice must not re-wrap.
        (TransportError.Other("passthrough"), .Other("passthrough")),
    ] as [(any Error & Sendable, TransportError)])
    func errorsMapOntoTheTaxonomy(error: any Error & Sendable, expected: TransportError) {
        #expect(error.asTransportError == expected)
    }

    @Test("A connection error keeps the URLError code, not a localized string")
    func connectionErrorKeepsTheCode() {
        let mapped = URLError(.secureConnectionFailed).asTransportError

        guard case let .Connection(message) = mapped else {
            Issue.record("expected .Connection, got \(mapped)")
            return
        }
        // -1200: a TLS trust failure has to stay distinguishable from a plain drop (#1074).
        #expect(message.contains("\(URLError.Code.secureConnectionFailed.rawValue)"))
    }
}

/// `livekit-net` hands the Swift side a method, headers and a body; these are what
/// reach the wire.
@Suite(.tags(.networking))
struct RustHTTPRequestTests {
    private let url = URL(string: "https://example.test/path")!

    @Test("Every verb maps to its method", arguments: zip([HttpMethod.get, .post], ["GET", "POST"]))
    func verbMapsToMethod(method: HttpMethod, expected: String) {
        let request = HttpClientAdapter.makeRequest(method: method, url: url, headers: [], body: nil)

        #expect(request.httpMethod == expected)
    }

    @Test("Headers and body are forwarded")
    func headersAndBodyAreForwarded() {
        let request = HttpClientAdapter.makeRequest(method: .post,
                                                    url: url,
                                                    headers: [Header(name: "Authorization", value: "Bearer t"),
                                                              Header(name: "X-Trace", value: "1")],
                                                    body: Data([0x01, 0x02]))

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(request.value(forHTTPHeaderField: "X-Trace") == "1")
        #expect(request.httpBody == Data([0x01, 0x02]))
    }
}
