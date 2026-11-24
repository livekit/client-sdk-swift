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
import LiveKitFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// A finished collector answer, delivered in `chunk`-sized pieces.
final class ChunkedCollector: URLProtocol, @unchecked Sendable {
    static let size = StateSync(0)
    static let chunk = 1000

    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "chunked.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "17"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var left = Self.size.copy()
        while left > 0 {
            let count = min(left, Self.chunk)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x78, count: count))
            left -= count
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A collector that answers 10 bytes and then nothing, or fails before any answer.
final class StalledCollector: URLProtocol, @unchecked Sendable {
    static let started = StateSync(0)
    static let stopped = StateSync(0)

    override static func canInit(with request: URLRequest) -> Bool { ["stalled.test", "refused.test"].contains(request.url?.host) }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { Self.stopped.mutate { $0 += 1 } }

    override func startLoading() {
        guard request.url?.host == "stalled.test" else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        Self.started.mutate { $0 += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x78, count: 10))
    }
}

/// Holds an object without keeping it alive.
final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
}

/// D03/P01 as the core sees it, on every OS (one delegate reader, no availability branch): an
/// answer up to 65,536 decoded bytes comes back whole, a longer one is cut one byte past the
/// limit (the core's overflow signal) with status and `Retry-After` kept, and every read ends
/// exactly once: answered, failed or cancelled, with nothing left registered.
@Suite(.serialized) struct TelemetryTransportCapTests {
    private static func transport() -> URLSessionTelemetryTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedCollector.self, StalledCollector.self, EndlessCollector.self]
        return URLSessionTelemetryTransport(session: URLSession(configuration: configuration))
    }

    private static func request(_ host: String) -> ExportRequest {
        ExportRequest(url: "https://\(host)/v1/logs", headers: [:], body: Data())
    }

    private func send(bodySize: Int) async throws -> ExportResponse {
        ChunkedCollector.size.mutate { $0 = bodySize }
        let transport = Self.transport()
        let response = try await transport.send(request: Self.request("chunked.test"))
        #expect(transport.reader.pending == 0)
        return response
    }

    @Test(arguments: [0, 65535, 65536])
    func answerAtOrBelowTheLimitComesBackWhole(size: Int) async throws {
        let response = try await send(bodySize: size)
        #expect(response.body.count == size)
        #expect(response.status == 503)
    }

    /// 1,000-byte chunks do not end at 65,537: only a reader that appends the remaining prefix of
    /// a chunk returns exactly one byte past the limit.
    @Test(arguments: [65537, 200_000])
    func longerAnswerIsCutOnePastTheLimit(size: Int) async throws {
        let response = try await send(bodySize: size)
        #expect(response.body.count == URLSessionTelemetryTransport.maxResponseBytes + 1)
        #expect(response.status == 503)
        #expect(response.headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value == "17")
    }

    /// The answer never ends: only a read that stops itself returns.
    @Test(.timeLimit(.minutes(1))) func anEndlessAnswerIsCutAndItsTaskCancelled() async throws {
        EndlessCollector.stopped.mutate { $0 = false }
        let transport = Self.transport()
        let response = try await transport.send(request: Self.request("endless.test"))
        #expect(response.body.count == URLSessionTelemetryTransport.maxResponseBytes + 1)
        #expect(response.status == 503)
        try await poll(for: "the endless answer's loading stopped") { EndlessCollector.stopped.copy() }
        #expect(transport.reader.pending == 0)
    }

    @Test func noAnswerIsARetryableError() async throws {
        let transport = Self.transport()
        await #expect(throws: ExportError.self) { try await transport.send(request: Self.request("refused.test")) }
        #expect(transport.reader.pending == 0)
    }

    /// Cancelled before the task is even registered: still one ending, no answer, nothing left.
    @Test func cancellingBeforeTheReadStartsEndsIt() async throws {
        let transport = Self.transport()
        let before = StalledCollector.started.copy()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(request: Self.request("stalled.test"))
        }
        await #expect(throws: ExportError.self) { try await task.value }
        #expect(transport.reader.pending == 0)
        #expect(StalledCollector.started.copy() == before)
    }

    @Test func cancellingDuringTheReadEndsItAndStopsTheTask() async throws {
        let transport = Self.transport()
        let (started, stopped) = (StalledCollector.started.copy(), StalledCollector.stopped.copy())
        let task = Task { try await transport.send(request: Self.request("stalled.test")) }
        try await poll(for: "the stalled answer started") { StalledCollector.started.copy() > started }
        task.cancel()
        await #expect(throws: ExportError.self) { try await task.value }
        try await poll(for: "the stalled answer's loading stopped") { StalledCollector.stopped.copy() > stopped }
        #expect(transport.reader.pending == 0)
    }

    /// A real socket (`LK_TELEMETRY_LOOPBACK`, a local server): a gzip answer is counted in
    /// decoded bytes, and the default session follows a same-origin redirect but answers with
    /// the 3xx for another origin.
    private static let loopback = ProcessInfo.processInfo.environment["LK_TELEMETRY_LOOPBACK"]

    private func sendToLoopback(_ path: String) async throws -> ExportResponse {
        let base = try #require(Self.loopback)
        let transport = URLSessionTelemetryTransport()
        let response = try await transport.send(request: ExportRequest(url: base + path, headers: [:], body: Data("probe".utf8)))
        #expect(transport.reader.pending == 0)
        return response
    }

    @Test(.enabled(if: loopback != nil))
    func loopbackGzipAnswerIsCountedDecoded() async throws {
        let response = try await sendToLoopback("/gzip")
        #expect(response.body.count == URLSessionTelemetryTransport.maxResponseBytes + 1)
        #expect(response.status == 503)
        #expect(response.headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value == "17")
    }

    @Test(.enabled(if: loopback != nil))
    func loopbackRedirects() async throws {
        #expect(try await sendToLoopback("/redirect-same").status == 200)
        #expect(try await sendToLoopback("/redirect-cross").status == 307)
    }

    /// The transport owns its session and the session its reader: releasing the transport
    /// releases both once the last read has ended.
    @Test func releasingTheTransportReleasesItsReader() async throws {
        ChunkedCollector.size.mutate { $0 = 10 }
        let reader = WeakReference<BoundedReader>()
        do {
            let transport = Self.transport()
            reader.value = transport.reader
            _ = try await transport.send(request: Self.request("chunked.test"))
        }
        try await poll(for: "the reader was released") { reader.value == nil }
    }
}
