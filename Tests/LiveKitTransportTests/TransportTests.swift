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
import Testing

@Test func invalidHTTPURL() async {
    await #expect(throws: TransportError.self) {
        _ = try await NativeHTTPClient().request(method: .get, url: "file:///etc/hosts", headers: [], body: nil)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVEKIT_TRANSPORT_TEST_URL"] != nil), .timeLimit(.minutes(1)))
struct TransportSocketTests {
    var http: String { ProcessInfo.processInfo.environment["LIVEKIT_TRANSPORT_TEST_URL"] ?? "" }
    var ws: String { http.replacingOccurrences(of: "http://", with: "ws://") }
    var tls: String { ProcessInfo.processInfo.environment["LIVEKIT_TRANSPORT_TLS_URL"] ?? "" }

    @Test func httpErrorsAndDecodedGzip() async throws {
        let client = NativeHTTPClient()
        let response = try await client.request(method: .get, url: http + "/error", headers: [], body: nil)
        #expect(response.status == 429)
        #expect(response.body == Data("error body".utf8))
        #expect(response.headers.contains { $0.name.lowercased() == "retry-after" && $0.value == "7" })
        let decoded = try await client.request(method: .get, url: http + "/gzip", headers: [], body: nil)
        #expect(decoded.body == Data("decoded body".utf8))
        #expect(!decoded.headers.contains { ["content-encoding", "content-length"].contains($0.name.lowercased()) })
        let posted = try await client.request(method: .post, url: http, headers: [], body: Data("posted".utf8))
        #expect(posted.status == 201)
        #expect(posted.body == Data("posted".utf8))
    }

    @Test func httpTimeout() async {
        await #expect(throws: TransportError.Timeout) {
            _ = try await NativeHTTPClient().request(method: .get, url: http + "/pending", headers: [], body: nil)
        }
    }

    @Test func httpCancellation() async throws {
        let request = Task { try await NativeHTTPClient().request(method: .get, url: http + "/pending", headers: [], body: nil) }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()
        await #expect(throws: TransportError.Closed) { _ = try await request.value }
    }

    @Test func tlsRejection() async {
        await #expect(throws: TransportError.self) {
            _ = try await NativeHTTPClient().request(method: .get, url: tls, headers: [], body: nil)
        }
        await #expect(throws: TransportError.self) {
            _ = try await NativeWebSocketClient().connect(url: tls.replacingOccurrences(of: "https://", with: "wss://"), headers: [], timeoutMs: 2000)
        }
    }

    @Test func connectTimeoutAndCancellation() async throws {
        await #expect(throws: TransportError.Timeout) {
            _ = try await NativeWebSocketClient().connect(url: ws + "/pending", headers: [], timeoutMs: 100)
        }
        let connect = Task { try await NativeWebSocketClient().connect(url: ws + "/pending", headers: [], timeoutMs: 10000) }
        try await Task.sleep(for: .milliseconds(100))
        connect.cancel()
        await #expect(throws: TransportError.Closed) { _ = try await connect.value }
    }

    @Test func peerCloseAndTextFrames() async throws {
        let client = NativeWebSocketClient()
        let closed = try await client.connect(url: ws + "/close", headers: [], timeoutMs: 2000).connection
        #expect(try await closed.recv() == nil)
        await closed.close()
        let text = try await client.connect(url: ws + "/text", headers: [], timeoutMs: 2000).connection
        #expect(try await text.recv() == Data("binary".utf8))
        await text.close()
    }

    @Test(arguments: [false, true]) func receiveCancellationAndClose(cancel: Bool) async throws {
        let connection = try await NativeWebSocketClient().connect(url: ws + "/echo", headers: [], timeoutMs: 2000).connection
        let receive = Task { try await connection.recv() }
        try await Task.sleep(for: .milliseconds(100))
        if cancel { receive.cancel() } else { await connection.close() }
        do {
            #expect(try await receive.value == nil)
        } catch {
            #expect(error as? TransportError == .Closed)
        }
    }

    @Test func cancelledSendAndConnectionRelease() async throws {
        let connection = try await NativeWebSocketClient().connect(url: ws + "/echo", headers: [], timeoutMs: 2000).connection
        let gate = Completion<Void>()
        let send = Task {
            try await gate.value()
            try await connection.send(frame: Data("cancelled".utf8))
        }
        send.cancel()
        gate.resolve(.success(()))
        await #expect(throws: TransportError.Closed) { try await send.value }
        await connection.close()

        var disposable: WsConnectResult? = try await NativeWebSocketClient().connect(url: ws + "/echo", headers: [], timeoutMs: 10000)
        let references = NSHashTable<AnyObject>.weakObjects()
        references.add(disposable?.connection)
        await disposable?.connection.close()
        disposable = nil
        #expect(references.allObjects.isEmpty)
    }

    @Test func independentConnections() async throws {
        let client = NativeWebSocketClient()
        let first = try await client.connect(url: ws + "/echo", headers: [], timeoutMs: 2000).connection
        let second = try await client.connect(url: ws + "/echo", headers: [], timeoutMs: 2000).connection
        await first.close()
        try await second.send(frame: Data("survivor".utf8))
        #expect(try await second.recv() == Data("survivor".utf8))
        await second.close()
    }
}

// Run each registry test in its own process via LIVEKIT_TRANSPORT_REGISTRY_CASE.
// Never reset or replace the process-wide Rust registry.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVEKIT_TRANSPORT_REGISTRY_CASE"] != nil), .timeLimit(.minutes(1)))
struct TransportRegistryTests {
    @Test func isolatedRegistry() async throws {
        let mode = ProcessInfo.processInfo.environment["LIVEKIT_TRANSPORT_REGISTRY_CASE"] ?? ""
        let http = CountingHTTPClient()
        let ws = CountingWSClient()
        #expect(!hasHttpClient())
        #expect(!hasWsClient())
        if mode != "ws-only" { setHttpClient(c: http) }
        if mode != "http-only" { setWsClient(c: ws) }
        if mode == "roundtrip" {
            let url = try #require(ProcessInfo.processInfo.environment["LIVEKIT_TRANSPORT_TEST_URL"])
            #expect(try await selfTestHttpGet(url: url + "/gzip").body == Data("decoded body".utf8))
            #expect(try await selfTestWsEcho(url: url.replacingOccurrences(of: "http://", with: "ws://") + "/echo", payload: Data("ffi".utf8)) == Data("ffi".utf8))
            #expect(http.calls == 1)
            #expect(ws.calls == 1)
            LiveKitTransport.initialize() // Losing registrations must leave the original clients in place.
            _ = try await selfTestHttpGet(url: url)
            #expect(http.calls == 2)
        } else if mode == "pending-connect" || mode == "foreign-timeout" {
            try await checkPendingConnect(ws, cancelSession: mode == "pending-connect")
        } else {
            let native = FfiRoom()
            do {
                _ = try await native.connect(url: "ws://127.0.0.1:1", token: "test", options: .init())
                Issue.record("Missing client unexpectedly connected")
            } catch {
                #expect(error as? FfiRoomError == .Signal(failure: .transportNotConfigured))
            }
            await native.disconnect()
        }
    }

    private func checkPendingConnect(_ ws: CountingWSClient, cancelSession: Bool) async throws {
        let native = FfiRoom()
        let options = FfiRoomOptions().withJoinRetries(value: 0).withConnectTimeout(value: Double(CountingWSClient.connectTimeoutMs) / 1000)
        let connect = Task { try await native.connect(url: "ws://127.0.0.1:1", token: "test", options: options) }
        let callbackStarted = try await ws.started.value()
        if cancelSession {
            let requested = ContinuousClock.now
            await Task.detached { native.cancel() }.value
            await #expect(throws: FfiRoomError.Cancelled) { _ = try await connect.value }
            let publicLatency = requested.duration(to: .now)
            print("Session cancel to public connect result: \(publicLatency)")
            #expect(publicLatency < .seconds(1))
        }

        // Session cancellation deliberately leaves core connect alive. Its signaling deadline
        // drops the foreign future; that drop must cancel the generated Swift callback Task.
        // foreign-timeout exercises the same drop without calling native.cancel() at all.
        let callbackCancelled = try await ws.cancelled.value()
        let callbackLatency = callbackStarted.duration(to: callbackCancelled)
        let signalingDeadline = Duration.milliseconds(Int64(CountingWSClient.connectTimeoutMs))
        let schedulingTolerance = Duration.seconds(1)
        print("Foreign callback cancellation: \(callbackLatency); deadline: \(signalingDeadline); tolerance: \(schedulingTolerance)")
        #expect(callbackLatency < signalingDeadline + schedulingTolerance)
        if !cancelSession {
            await #expect(throws: FfiRoomError.self) { _ = try await connect.value }
        }
        // Join the session's owned work, not an asserted all-descendant destruction barrier.
        await native.disconnect()
        #expect(ws.calls == 1)
    }
}

private final class CountingHTTPClient: HttpClient, @unchecked Sendable {
    // Test-only counters, protected by lock; no production telemetry.
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func request(method: HttpMethod, url: String, headers: [Header], body: Data?) async throws -> HttpResponse {
        lock.withLock { count += 1 }
        return try await NativeHTTPClient().request(method: method, url: url, headers: headers, body: body)
    }
}

private final class CountingWSClient: WsClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    // Longer than the public-return bound, so that bound cannot pass by waiting for timeout.
    static let connectTimeoutMs: UInt64 = 2000
    let started = Completion<ContinuousClock.Instant>()
    let cancelled = Completion<ContinuousClock.Instant>()
    func connect(url: String, headers: [Header], timeoutMs: UInt64) async throws -> WsConnectResult {
        lock.withLock { count += 1 }
        let mode = ProcessInfo.processInfo.environment["LIVEKIT_TRANSPORT_REGISTRY_CASE"]
        if mode == "pending-connect" || mode == "foreign-timeout" {
            #expect(timeoutMs == Self.connectTimeoutMs)
            // Deliberately suspended foreign callback: unlike the production adapter, this
            // fake has no timer. Rust's signaling timeout owns the drop under test.
            let pending = Completion<WsConnectResult>()
            return try await withTaskCancellationHandler {
                started.resolve(.success(.now))
                return try await pending.value()
            } onCancel: {
                pending.resolve(.failure(TransportError.Closed))
                cancelled.resolve(.success(.now))
            }
        }
        return try await NativeWebSocketClient().connect(url: url, headers: headers, timeoutMs: timeoutMs)
    }
}
