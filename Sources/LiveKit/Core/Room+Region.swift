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

extension Room {
    // MARK: - Internal

    func regionManager(for providedUrl: URL) async -> RegionManager? {
        guard providedUrl.isCloud, providedUrl.host != nil else {
            let old = _regionManager.mutate { manager -> RegionManager? in
                let old = manager
                manager = nil
                return old
            }
            if let old { await old.cancel() }
            return nil
        }

        let (manager, old) = _regionManager.mutate { current -> (RegionManager, RegionManager?) in
            if let manager = current, manager.providedUrl.matchesRegionManagerKey(of: providedUrl) {
                return (manager, nil)
            }

            let old = current
            let manager = RegionManager(providedUrl: providedUrl)
            current = manager
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
    public func prepareConnection(url providedUrlString: String, token: String? = nil) async throws {
        // Must be in disconnected state.
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
                $0.preparedRegion = nil
            }

            guard let regionManager = await regionManager(for: providedUrl) else {
                Task {
                    await HTTP.prewarmConnection(url: providedUrl)
                    log("Prepared connection to \(providedUrl)")
                }
                return
            }

            // Nothing to prewarm if every region has already been tried; the connect path will
            // surface why.
            if let bestRegion = try await regionManager.resolveBest(token: token) {
                _state.mutate { $0.preparedRegion = bestRegion }
                Task {
                    await HTTP.prewarmConnection(url: bestRegion.url)
                    log("Prepared connection to \(bestRegion.url)")
                }
            }
        } else {
            // Not cloud or no token, just warm the provided URL
            Task {
                await HTTP.prewarmConnection(url: providedUrl)
                log("Prepared connection to \(providedUrl)")
            }
        }
    }

    // MARK: - Internal

    func consumePreparedRegion(for providedUrl: URL) -> RegionInfo? {
        let snapshot = _state.read { (region: $0.preparedRegion, url: $0.providedUrl) }
        let isPreparedUrlMatching = if let existing = snapshot.url {
            existing.matchesRegionManagerKey(of: providedUrl)
        } else {
            false
        }

        if snapshot.region != nil, !isPreparedUrlMatching {
            log("Discarding prepared region, URL changed to \(providedUrl)", .info)
        }

        return _state.mutate { state -> RegionInfo? in
            let prepared = isPreparedUrlMatching ? snapshot.region : nil
            state.preparedRegion = nil
            return prepared
        }
    }

    /// Bounds ``connectWithCloudRegionFailover``, independently of how the region list is
    /// maintained.
    ///
    /// The list is refreshed from the server *inside* the loop, so termination must not rest on an
    /// invariant about how `remaining` is kept. rust-sdks gets this structurally — its fallback
    /// iterates a list fetched once (`for region_url in urls.iter()` in `livekit-signaling`), so
    /// nothing can refill it mid-loop. Until this loop is reshaped the same way, the cap is what
    /// guarantees `connect` returns rather than hangs. Comfortably above any real region count.
}
