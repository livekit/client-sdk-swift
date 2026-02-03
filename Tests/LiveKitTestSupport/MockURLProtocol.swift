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
import LiveKit

public final class MockURLProtocol: URLProtocol {
    public struct Response: Sendable {
        public let statusCode: Int
        public let headers: [String: String]
        public let body: Data

        public init(statusCode: Int, headers: [String: String], body: Data) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }
    }

    private struct State: Sendable {
        var allowedHosts = Set<String>()
        var allowedPaths = Set<String>()
        var requestHandler: (@Sendable (URLRequest) throws -> Response)?
    }

    private static let _state = StateSync(State())

    public static func setAllowedHosts(_ hosts: Set<String>) {
        _state.mutate { $0.allowedHosts = hosts }
    }

    public static func setAllowedPaths(_ paths: Set<String>) {
        _state.mutate { $0.allowedPaths = paths }
    }

    public static func setRequestHandler(_ handler: (@Sendable (URLRequest) throws -> Response)?) {
        _state.mutate { $0.requestHandler = handler }
    }

    public static func reset() {
        _state.mutate {
            $0.allowedHosts = []
            $0.allowedPaths = []
            $0.requestHandler = nil
        }
    }

    // swiftlint:disable:next static_over_final_class
    override public class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        let (allowedHosts, allowedPaths) = _state.read { ($0.allowedHosts, $0.allowedPaths) }
        guard let host = url.host, allowedHosts.contains(host) else { return false }
        guard allowedPaths.contains(url.path) else { return false }
        return true
    }

    // swiftlint:disable:next static_over_final_class
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        guard let handler = Self._state.read({ $0.requestHandler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let mock = try handler(request)
            let url = request.url!
            let response = HTTPURLResponse(url: url,
                                           statusCode: mock.statusCode,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: mock.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: mock.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {
        // No-op.
    }
}
