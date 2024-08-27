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

    func resolveNextBestRegionUrl() async throws -> URL {
        if shouldRequestRegionSettings() {
            try await requestRegionSettings()
        }

        let (allRegions, failedRegions) = _state.read { ($0.allRegions, $0.failedRegions) }

        let remainingRegions = allRegions.filter { region in
            !failedRegions.contains { $0 == region }
        }

        guard let selectedRegion = remainingRegions.first else {
            throw LiveKitError(.regionUrlProvider, message: "No more remaining regions.")
        }

//        _state.mutate {
//            $0.allRegions.append(selectedRegion)
//        }

        let result = selectedRegion.url.toSocketUrl()
        log("[Region] Resolved region url: \(String(describing: result))")

        return result
    }

    // MARK: - Private

    private func shouldRequestRegionSettings() -> Bool {
        _state.read {
            guard !$0.allRegions.isEmpty, let regionSettingsUpdated = $0.regionDataUpdated else { return true }
            let interval = Date().timeIntervalSince(regionSettingsUpdated)
            return interval > Self.defaultCacheInterval
        }
    }

    private func requestRegionSettings() async throws {
        let (serverUrl, token) = _state.read { ($0.url, $0.token) }

        guard let serverUrl, let token else {
            throw LiveKitError(.invalidState)
        }

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

            _state.mutate {
                $0.allRegions = allRegions
                $0.regionDataUpdated = Date()
            }
        } catch {
            throw LiveKitError(.regionUrlProvider, message: "Failed to parse region settings with error: \(error)")
        }
    }
}
