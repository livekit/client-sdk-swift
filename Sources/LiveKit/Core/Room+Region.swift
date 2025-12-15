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

// MARK: - Room+Region

extension Room {
    // MARK: - Public

    // prepareConnection should be called as soon as the page is loaded, in order
    // to speed up the connection attempt.
    //
    // With LiveKit Cloud, it will also determine the best edge data center for
    // the current client to connect to if a token is provided.
    public func prepareConnection(url providedUrlString: String, token: String? = nil) async {
        // Must be in disconnected state.
        guard _state.connectionState == .disconnected else {
            log("Room is not in disconnected state", .info)
            return
        }

        guard let providedUrl = URL(string: providedUrlString), providedUrl.isValidForConnect else {
            log("URL parse failed", .error)
            return
        }

        log("Preparing connection to \(providedUrlString)")

        do {
            if providedUrl.isCloud, let token {
                _state.mutate {
                    $0.providedUrl = providedUrl
                    $0.token = token
                }

                // Try to get the best region and warm that connection
                if let bestRegion = await regionManager.tryResolveBest(providedUrl: providedUrl, token: token) {
                    // Warm connection to the best region
                    await HTTP.prewarmConnection(url: bestRegion.url)
                    log("Prepared connection to \(bestRegion.url)")
                } else {
                    // Fallback to warming the provided URL
                    await HTTP.prewarmConnection(url: providedUrl)
                    log("Prepared connection to \(providedUrl)")
                }
            } else {
                // Not cloud or no token, just warm the provided URL
                await HTTP.prewarmConnection(url: providedUrl)
                log("Prepared connection to \(providedUrl)")
            }
        } catch {
            log("Error while preparing connection: \(error)")
            // Still try to warm the provided URL as fallback
            await HTTP.prewarmConnection(url: providedUrl)
            log("Prepared fallback connection to \(providedUrl)")
        }
    }

    // MARK: - Internal

    /// Connects using LiveKit Cloud region settings and fails over across regions on retryable errors.
    func connectWithCloudRegionFailover(
        providedUrl: URL,
        initialUrl: URL,
        initialRegion: RegionInfo?,
        token: String,
        prepareBeforeFirstAttempt: (@Sendable () async -> Void)? = nil,
        prepareAfterFailure: @Sendable () async -> Void
    ) async throws -> URL {
        precondition(providedUrl.isCloud, "connectWithCloudRegionFailover is only valid for LiveKit Cloud URLs")

        var nextUrl = initialUrl
        var nextRegion = initialRegion

        if let prepareBeforeFirstAttempt {
            await prepareBeforeFirstAttempt()
        }

        while true {
            do {
                try await fullConnectSequence(nextUrl, token)
                return nextUrl
            } catch {
                // Re-throw if is cancel.
                if error is CancellationError {
                    throw error
                }

                if let liveKitError = error as? LiveKitError, liveKitError.type == .validation {
                    // Don't retry other regions for validation errors.
                    throw liveKitError
                }

                guard error.isRetryableForRegionFailover else {
                    throw error
                }

                if let region = nextRegion {
                    nextRegion = nil
                    log("Connect failed with region: \(region)")
                    await regionManager.markFailed(region: region)
                }

                try Task.checkCancellation()

                await prepareAfterFailure()

                let region = try await regionManager.resolveBest(providedUrl: providedUrl, token: token)
                nextUrl = region.url
                nextRegion = region
            }
        }
    }
}
