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

/// Protocol for token servers that fetch credentials via HTTP requests.
/// Provides a default implementation of `fetch` that can be used to integrate with custom backend token generation endpoints.
/// - Note: The response is expected to be a `Token.Response` object.
public protocol EndpointTokenSource: TokenSourceConfigurable {
    /// The URL endpoint for token generation.
    var url: URL { get }
    /// The HTTP method to use (defaults to "POST").
    var method: String { get }
    /// Additional HTTP headers to include with the request.
    var headers: [String: String] { get }
}

public extension EndpointTokenSource {
    var method: String { "POST" }
    var headers: [String: String] { [:] }

    func fetch(_ options: TokenRequestOptions) async throws -> TokenSourceResponse {
        var urlRequest = URLRequest(url: url)

        urlRequest.httpMethod = method
        for (key, value) in headers {
            urlRequest.addValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try JSONEncoder().encode(options)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveKitError(.network, message: "Error generating token from the token server, no response")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw LiveKitError(.network, message: "Error generating token from the token server, received \(httpResponse)")
        }

        return try JSONDecoder().decode(TokenSourceResponse.self, from: data)
    }
}
