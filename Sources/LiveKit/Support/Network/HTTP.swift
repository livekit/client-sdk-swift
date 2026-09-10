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

class HTTP: NSObject {
    private static let operationQueue = OperationQueue()

    private static let session: URLSession = .init(configuration: .default,
                                                   delegate: nil,
                                                   delegateQueue: operationQueue)

    /// Perform one request on the shared session.
    ///
    /// Both parameters are applied to `request`, overriding whatever it carries, so the
    /// transport owns them rather than each call site.
    ///
    /// - Parameter cachePolicy: Defaults to bypassing the cache: the shared session uses
    ///   `URLCache.shared`, and a cached validation or region response is a stale one.
    /// - Parameter timeoutInterval: Defaults to ``TimeInterval/defaultHTTPConnect``.
    static func request(_ request: URLRequest,
                        cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalAndRemoteCacheData,
                        timeoutInterval: TimeInterval = .defaultHTTPConnect) async throws -> (Data, HTTPURLResponse)
    {
        var request = request
        request.cachePolicy = cachePolicy
        request.timeoutInterval = timeoutInterval
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }

    static func requestValidation(from url: URL, token: String) async throws {
        var request = URLRequest(url: url)
        // Attach token to header
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await Self.request(request,
                                                          cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                                          timeoutInterval: .defaultHTTPConnect)

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let statusCode = httpResponse.statusCode
            let rawBody = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let body = if let rawBody, !rawBody.isEmpty {
                rawBody.count > 1024 ? String(rawBody.prefix(1024)) + "..." : rawBody
            } else {
                "(No server message)"
            }

            let details = "HTTP \(statusCode): \(body)"

            // Treat request/token/permissions issues as validation errors.
            // 404 is reported separately so the v1 → v0 RTC path fallback can
            // distinguish "endpoint doesn't exist" from other client errors.
            if (400 ..< 500).contains(statusCode), statusCode != 429 {
                throw LiveKitError(statusCode == 404 ? .serviceNotFound : .validation, message: details)
            }

            // Treat server/rate-limit issues as network errors.
            throw LiveKitError(.network, message: "Validation endpoint error: \(details)")
        }
    }

    static func prewarmConnection(url: URL) async {
        // Convert WebSocket URL to HTTP for warming
        let httpUrl = url.toHTTPUrl()
        do {
            var request = URLRequest(url: httpUrl)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 10
            _ = try await session.data(for: request)
        } catch {
            // Silently fail - connection warming is best effort
        }
    }
}
