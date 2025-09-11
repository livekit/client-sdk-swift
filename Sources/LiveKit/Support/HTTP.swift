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

enum ServerValidationResponse {
    case valid
    case invalid(message: String)
    // Network error etc.
    case unknown(error: Error)
}

class HTTP: NSObject {
    static let statusCodeOK = 200

    private static let operationQueue = OperationQueue()

    private static let session: URLSession = .init(configuration: .default,
                                                   delegate: nil,
                                                   delegateQueue: operationQueue)

    static func requestValidation(from url: URL, token: String) async -> ServerValidationResponse {
        do {
            var request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                     timeoutInterval: .defaultHTTPConnect)
            // Attach token to header
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            // Make the data request
            let (data, response) = try await session.data(for: request)

            // Print HTTP status code
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            // Valid if 200
            if httpResponse.statusCode == statusCodeOK {
                return .valid
            }

            guard let string = String(data: data, encoding: .utf8) else {
                throw URLError(.badServerResponse)
            }

            // Consider anything other than 200 invalid
            return .invalid(message: string)
        } catch {
            return .unknown(error: error)
        }
    }
}
