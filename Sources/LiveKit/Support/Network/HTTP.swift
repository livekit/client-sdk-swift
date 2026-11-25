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

internal import LiveKitTransport
import Foundation

enum HTTP {
    private static let operationQueue = OperationQueue()

    private static let session: URLSession = .init(configuration: .default,
                                                   delegate: nil,
                                                   delegateQueue: operationQueue)

    static func prewarmConnection(url: URL) async {
        LiveKitTransport.initialize()
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
