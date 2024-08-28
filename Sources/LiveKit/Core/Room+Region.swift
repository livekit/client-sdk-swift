/*
 * Copyright 2024 LiveKit
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
    static let defaultCacheInterval: TimeInterval = 3000

    func resolveBestRegion() async throws -> RegionInfo {
        try await requestRegionSettings()

        guard let selectedRegion = _regionState.remaining.first else {
            throw LiveKitError(.regionUrlProvider, message: "No more remaining regions.")
        }

        log("[Region] Resolved region: \(String(describing: selectedRegion))")

        return selectedRegion
    }

    func add(failedRegion region: RegionInfo) {
        _regionState.mutate {
            $0.remaining.removeAll { $0 == region }
        }
    }

    // MARK: - Private

    private func requestRegionSettings() async throws {
        let (serverUrl, token) = _state.read { ($0.url, $0.token) }

        guard let serverUrl, let token else {
            throw LiveKitError(.invalidState)
        }

        let shouldRequestRegionSettings = _regionState.read {
            guard serverUrl == $0.url, let regionSettingsUpdated = $0.lastRequested else { return true }
            let interval = Date().timeIntervalSince(regionSettingsUpdated)
            log("[Region] Interval: \(String(describing: interval))")
            return interval > Self.defaultCacheInterval
        }

        guard shouldRequestRegionSettings else { return }

        // Ensure url is for cloud.
        guard serverUrl.isCloud() else {
            throw LiveKitError(.onlyForCloud)
        }

        // Make a request which ignores cache.
        var request = URLRequest(url: serverUrl.regionSettingsUrl(),
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)

        request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")

        log("[Region] Requesting region settings...")

        let (data, response) = try await URLSession.shared.data(for: request)
        // Response must be a HTTPURLResponse.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveKitError(.regionUrlProvider, message: "Failed to fetch region settings")
        }

        // Check the status code.
        guard httpResponse.isStatusCodeOK else {
            log("[Region] Failed to fetch region settings, error: \(String(describing: httpResponse))", .error)
            throw LiveKitError(.regionUrlProvider, message: "Failed to fetch region settings with status code: \(httpResponse.statusCode)")
        }

        do {
            // Try to parse the JSON data.
            let regionSettings = try Livekit_RegionSettings(jsonUTF8Data: data)
            let allRegions = regionSettings.regions.compactMap { $0.toLKType() }

            if allRegions.isEmpty {
                throw LiveKitError(.regionUrlProvider, message: "Fetched region data is empty.")
            }

            log("[Region] all regions: \(String(describing: allRegions))")

            _regionState.mutate {
                $0.url = serverUrl
                $0.all = allRegions
                $0.remaining = allRegions
                $0.lastRequested = Date()
            }
        } catch {
            throw LiveKitError(.regionUrlProvider, message: "Failed to parse region settings with error: \(error)")
        }
    }
}
