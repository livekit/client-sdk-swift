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

final class NativeHTTPClient: HttpClient {
    // No room/session/delegate references are retained by the process-wide client.
    private let session = URLSession(configuration: .ephemeral)

    deinit { session.invalidateAndCancel() }

    func request(method: HttpMethod, url: String, headers: [Header], body: Data?) async throws -> HttpResponse {
        var request = try URLRequest(url: requestURL(url, schemes: ["http", "https"]))
        request.httpMethod = method == .get ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        for header in headers {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        let completion = Completion<HttpResponse>()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion.resolve(.failure(transportError(error)))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion.resolve(.failure(TransportError.Other("Missing HTTP response")))
                return
            }
            // URLSession decodes content encodings but can retain the compressed headers.
            // Rust must see the decoded body exactly once, with matching metadata.
            let headers = response.allHeaderFields.compactMap { key, value -> Header? in
                let name = String(describing: key)
                guard !["content-encoding", "content-length"].contains(name.lowercased()) else { return nil }
                return Header(name: name, value: String(describing: value))
            }
            completion.resolve(.success(HttpResponse(status: UInt16(response.statusCode), headers: headers, body: data ?? Data())))
        }
        return try await withTaskCancellationHandler {
            task.resume()
            return try await completion.value()
        } onCancel: {
            task.cancel()
            completion.resolve(.failure(TransportError.Closed))
        }
    }
}
