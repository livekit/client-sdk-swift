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
    // MARK: - Internal

    func regionManager(for providedUrl: URL) async -> RegionManager? {
        guard providedUrl.isCloud, providedUrl.host != nil else {
            let old = _regionManager.mutate { holder -> RegionManager? in
                let old = holder.manager
                holder.manager = nil
                return old
            }
            if let old { await old.cancel() }
            return nil
        }

        let (manager, old) = _regionManager.mutate { state -> (RegionManager, RegionManager?) in
            if let manager = state.manager, manager.providedUrl.matchesRegionManagerKey(of: providedUrl) {
                return (manager, nil)
            }

            let old = state.manager
            let manager = RegionManager(providedUrl: providedUrl)
            state.manager = manager
            return (manager, old)
        }

        if let old { await old.cancel() }
        return manager
    }

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

        if providedUrl.isCloud, let token {
            _state.mutate {
                $0.providedUrl = providedUrl
                $0.token = token
            }

            guard let regionManager = await regionManager(for: providedUrl) else {
                await HTTP.prewarmConnection(url: providedUrl)
                log("Prepared connection to \(providedUrl)")
                return
            }

            if let bestRegion = await regionManager.tryResolveBest(token: token) {
                await HTTP.prewarmConnection(url: bestRegion.url)
                log("Prepared connection to \(bestRegion.url)")
            } else {
                await HTTP.prewarmConnection(url: providedUrl)
                log("Prepared connection to \(providedUrl)")
            }
        } else {
            // Not cloud or no token, just warm the provided URL
            await HTTP.prewarmConnection(url: providedUrl)
            log("Prepared connection to \(providedUrl)")
        }
    }

    // MARK: - Internal

    /// Connects using LiveKit Cloud region settings and fails over across regions on retryable errors.
    func connectWithCloudRegionFailover(
        regionManager: RegionManager,
        initialUrl: URL,
        initialRegion: RegionInfo?,
        token: String,
        prepareBeforeFirstAttempt: (@Sendable () async -> Void)? = nil,
        prepareAfterFailure: @Sendable () async -> Void
    ) async throws -> URL {
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

                let region = try await regionManager.resolveBest(token: token)
                nextUrl = region.url
                nextRegion = region
            }
        }
    }
}
