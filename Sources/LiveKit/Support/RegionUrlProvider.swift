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

class RegionUrlProvider: Loggable {
    static let settingsCacheTime: TimeInterval = 3000

    private struct State {
        var serverUrl: URL
        var token: String
        var regionSettings: Livekit_RegionSettings?
        var regionSettingsUpdated: Date?
        var attemptedRegions: [Livekit_RegionInfo] = []
    }

    private let _state: StateSync<State>

    public var serverUrl: URL {
        _state.mutate { $0.serverUrl }
    }

    init(url: String, token: String) {
        let serverUrl = URL(string: url)!
        _state = StateSync(State(serverUrl: serverUrl, token: token))
    }

    func set(regionSettings: Livekit_RegionSettings) {
        _state.mutate {
            $0.regionSettings = regionSettings
            $0.regionSettingsUpdated = Date()
        }
    }

    func set(token: String) {
        _state.mutate { $0.token = token }
    }

    func resetAttempts() {
        _state.mutate {
            $0.attemptedRegions = []
        }
    }

    func shouldRequestRegionSettings() -> Bool {
        _state.read {
            guard $0.regionSettings != nil, let regionSettingsUpdated = $0.regionSettingsUpdated else {
                return true
            }

            let interval = Date().timeIntervalSince(regionSettingsUpdated)
            return interval > Self.settingsCacheTime
        }
    }

    func nextBestRegionUrl() async throws -> URL? {
        if shouldRequestRegionSettings() {
            try await requestRegionSettings()
        }

        let (regionSettings, attemptedRegions) = _state.read { ($0.regionSettings, $0.attemptedRegions) }

        guard let regionSettings else {
            return nil
        }

        let remainingRegions = regionSettings.regions.filter { region in
            !attemptedRegions.contains { $0.url == region.url }
        }

        guard let selectedRegion = remainingRegions.first else {
            return nil
        }

        _state.mutate {
            $0.attemptedRegions.append(selectedRegion)
        }

        return URL(string: selectedRegion.url)
    }

    func requestRegionSettings() async throws {
        let (serverUrl, token) = _state.read { ($0.serverUrl, $0.token) }

        // Ensure url is for cloud.
        guard serverUrl.isCloud() else {
            throw LiveKitError(.onlyForCloud)
        }

        var request = URLRequest(url: serverUrl.regionSettingsUrl())
        request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        // Response must be a HTTPURLResponse.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveKitError(.regionUrlProvider, message: "Failed to fetch region settings")
        }

        // Check the status code.
        guard httpResponse.isStatusCodeOK else {
            throw LiveKitError(.regionUrlProvider, message: "Failed to fetch region settings with status code: \(httpResponse.statusCode)")
        }

        do {
            // Try to parse the JSON data.
            let regionSettings = try Livekit_RegionSettings(jsonUTF8Data: data)
            _state.mutate {
                $0.regionSettings = regionSettings
                $0.regionSettingsUpdated = Date()
            }
        } catch {
            throw LiveKitError(.regionUrlProvider, message: "Failed to parse region settings with error: \(error)")
        }
    }
}
