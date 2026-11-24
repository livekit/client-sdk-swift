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

/// The D03/P01 response cap as the core sees it: an answer up to 65,536 decoded bytes comes back
/// whole, a longer one is cut one byte past the limit (the core's overflow signal), and status and
/// `Retry-After` survive the cut.
@Suite(.serialized) struct TelemetryTransportCapTests {
    private func send(bodySize: Int) async throws -> ExportResponse {
        ChunkedCollector.size.mutate { $0 = bodySize }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedCollector.self]
        let transport = URLSessionTelemetryTransport(session: URLSession(configuration: configuration))
        return try await transport.send(request: ExportRequest(url: "https://chunked.test/v1/logs", headers: [:], body: Data()))
    }

    @Test(arguments: [0, 65535, 65536])
    func answerAtOrBelowTheLimitComesBackWhole(size: Int) async throws {
        let response = try await send(bodySize: size)
        #expect(response.body.count == size)
        #expect(response.status == 503)
    }

    @Test(arguments: [65537, 200_000])
    func longerAnswerIsCutOnePastTheLimit(size: Int) async throws {
        let response = try await send(bodySize: size)
        #expect(response.body.count == URLSessionTelemetryTransport.maxResponseBytes + 1)
        #expect(response.status == 503)
        #expect(response.headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value == "17")
    }
}
