/*
 * Copyright 2025 LiveKit
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

final class MockURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    static var allowedHosts = Set<String>()
    static var allowedPaths = Set<String>()
    static var requestHandler: (@Sendable (URLRequest) throws -> Response)?

    static func reset() {
        allowedHosts = []
        allowedPaths = []
        requestHandler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        guard let host = url.host, allowedHosts.contains(host) else { return false }
        guard allowedPaths.contains(url.path) else { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
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

    override func stopLoading() {
        // No-op.
    }
}
