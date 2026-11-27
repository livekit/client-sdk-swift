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
@testable import LiveKitTransport
@testable import class LiveKitTransport.WebSocket
import Testing

/// The mapping the whole seam hinges on, exercised where a socket cannot reach it:
/// `ECONNRESET` mid-frame and a bare `URLError(.timedOut)` are not things a healthy
/// `livekit-server` will produce on demand.
@Suite(.tags(.networking), TestLimits.unit)
struct TransportErrorMappingTests {
    @Test("Errors map onto livekit-net's taxonomy", arguments: [
        // A rejected upgrade keeps its status, bare or wrapped by the socket.
        (WebSocketUpgradeFailure(statusCode: 401), TransportError.Http(status: 401)),
        (WebSocketError(.network, internalError: WebSocketUpgradeFailure(statusCode: 503)), .Http(status: 503)),
        (URLError(.timedOut), .Timeout),
        (WebSocketError(.timedOut), .Timeout),
        // Every abrupt teardown livekit-net folds into end-of-stream.
        (URLError(.cancelled), .Closed),
        (URLError(.networkConnectionLost), .Closed),
        (POSIXError(.ECONNRESET), .Closed),
        (POSIXError(.ENOTCONN), .Closed),
        (WebSocketError(.network, internalError: WebSocketClosedByPeer(code: 1000)), .Closed),
        (WebSocketError(.cancelled), .Closed),
        // Already ours: crossing the FFI twice must not re-wrap.
        (TransportError.Other("passthrough"), .Other("passthrough")),
    ] as [(any Error & Sendable, TransportError)])
    func errorsMapOntoTheTaxonomy(error: any Error & Sendable, expected: TransportError) {
        #expect(error.asTransportError == expected)
    }

    /// livekit-net's signal client fails fast on a rejected upgrade's status, which comes from the upgrade's own
    /// response: one request, no validation call.
    @Test("A rejected upgrade's status comes from its response")
    func rejectedUpgradeStatusComesFromTheResponse() async throws {
        let server = try FakeWebSocketServer(.reject(status: 401))
        defer { server.cancel() }
        let url = try await server.url()
        await #expect(throws: TransportError.Http(status: 401)) {
            try await NativeWebSocketClient().connect(url: url.absoluteString, headers: [Header(name: "Authorization", value: "Bearer test")],
                                                      timeoutMs: 10000)
        }
        #expect(server.requestHeaders.copy().contains("Authorization: Bearer test"))
        #expect(server.acceptCount.copy() == 1)
    }

    /// A rejection in HTTP/1.0 keeps its status too; a 101 in HTTP/1.0 does not open, and is no HTTP rejection.
    @Test("An HTTP/1.0 rejection keeps its status", arguments: [("HTTP/1.0 401 Unauthorized", 401), ("HTTP/1.0 503 Service Unavailable", 503)])
    func http10RejectionKeepsItsStatus(statusLine: String, status: Int) async throws {
        let server = try FakeWebSocketServer(.upgradeResponse(head: "\(statusLine)\r\nContent-Length: 0\r\n\r\n"))
        defer { server.cancel() }
        let url = try await server.url()
        await #expect(throws: TransportError.Http(status: UInt16(status))) {
            try await NativeWebSocketClient().connect(url: url.absoluteString, headers: [], timeoutMs: 10000)
        }
        #expect(server.acceptCount.copy() == 1)
    }

    @Test("An HTTP/1.0 101 does not open")
    func http10UpgradeDoesNotOpen() async throws {
        let head = "HTTP/1.0 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
        let server = try FakeWebSocketServer(.upgradeResponse(head: head))
        defer { server.cancel() }
        let url = try await server.url()
        let error = await #expect(throws: TransportError.self) {
            try await NativeWebSocketClient().connect(url: url.absoluteString, headers: [], timeoutMs: 10000)
        }
        guard case .Connection? = error else { return #expect(Bool(false), "Not a connection error: \(String(describing: error))") }
    }

    @Test("A send completion cancelled during teardown maps to Closed")
    func cancelledSendCompletionIsClosed() throws {
        let underlying = WebSocket.bridged(.posix(.ECANCELED))
        let urlError = try #require(underlying as? URLError)
        #expect(urlError.code == .cancelled)
        #expect(WebSocketError(.network, internalError: underlying).asTransportError == .Closed)
    }

    @Test("Fallback connection errors keep only their domain and code", arguments: [
        (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                 userInfo: [NSLocalizedDescriptionKey: "Permission refusée"]), "NSPOSIXErrorDomain 13"),
        (NSError(domain: "test.transport", code: 42,
                 userInfo: [NSLocalizedDescriptionKey: "Verbindung fehlgeschlagen"]), "test.transport 42"),
    ])
    func fallbackConnectionErrorIsStable(error: NSError, expected: String) {
        #expect(error.asTransportError == .Connection(expected))
        #expect(WebSocketError(.network, internalError: error).asTransportError == .Connection(expected))
    }

    @Test("A connection error keeps the SDK's explanation ahead of the code",
          .bug("https://github.com/livekit/client-sdk-swift/pull/1191"), arguments: [
              (WebSocketError(.network, message: "WebSocket protocol violation: the unknown opcode 3",
                              internalError: NSError(domain: NSPOSIXErrorDomain, code: Int(EPROTO))),
               "WebSocket protocol violation: the unknown opcode 3 (NSPOSIXErrorDomain 100)"),
              (WebSocketError(.network, message: "WebSocket upgrade response: no Upgrade header", internalError: URLError(.badServerResponse)),
               "WebSocket upgrade response: no Upgrade header (URLError -1011)"),
          ])
    func connectionErrorKeepsTheExplanation(error: WebSocketError, expected: String) {
        #expect(error.asTransportError == .Connection(expected))
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
