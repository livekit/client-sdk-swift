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

// MARK: - Room+Region

public extension Room {
    /// Validates the URL and warms the HTTP connection to it, to speed up a later ``connect(url:token:connectOptions:roomOptions:)``.
    ///
    /// - Note: The native session resolves the LiveKit Cloud region during connect, so this method
    ///   no longer fetches region settings and does not report region errors.
    func prepareConnection(url providedUrlString: String, token: String? = nil) async throws {
        guard _state.connectionState == .disconnected else {
            throw LiveKitError(.stateMismatch, message: "Cannot prepare connection when in state \(_state.connectionState)")
        }

        guard let providedUrl = URL(string: providedUrlString), providedUrl.isValidForConnect else {
            throw LiveKitError(.failedToParseUrl, message: "Invalid URL: \(providedUrlString)")
        }

        log("Preparing connection to \(providedUrlString)")

        if providedUrl.isCloud, let token {
            _state.mutate {
                $0.providedUrl = providedUrl
                $0.token = token
            }
        }

        Task {
            await HTTP.prewarmConnection(url: providedUrl)
            log("Prepared connection to \(providedUrl)")
        }
    }
}
