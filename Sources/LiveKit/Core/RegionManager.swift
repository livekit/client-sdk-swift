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

// MARK: - RegionManager

actor RegionManager: Loggable {
    struct State: Sendable {
        var url: URL?
        var lastRequested: Date?
        var all: [RegionInfo] = []
        var remaining: [RegionInfo] = []
    }

    static let cacheInterval: TimeInterval = 30

    private var state = State()
    private var settingsFetchTask: Task<Void, Error>?
    private var settingsFetchTaskID: UUID?

    func resetAttemptsIfExhausted() {
        guard state.remaining.isEmpty, !state.all.isEmpty else { return }
        state.remaining = state.all
    }

    func resetAttempts() {
        state.remaining = state.all
    }

    func markFailed(region: RegionInfo) {
        state.remaining.removeAll { $0 == region }
    }

    func shouldRequestSettings(for providedUrl: URL) -> Bool {
        guard providedUrl.isCloud else { return false }
        guard providedUrl == state.url, let lastRequested = state.lastRequested else { return true }
        return Date().timeIntervalSince(lastRequested) > Self.cacheInterval
    }

    func prepareSettingsFetch(providedUrl: URL, token: String) {
        guard shouldRequestSettings(for: providedUrl) else { return }
        startSettingsFetchIfNeeded(providedUrl: providedUrl, token: token)
    }

    func tryResolveBest(providedUrl: URL, token: String) async -> RegionInfo? {
        do {
            return try await resolveBest(providedUrl: providedUrl, token: token)
        } catch {
            log("[Region] Failed to resolve best region: \(error)", .warning)
            return nil
        }
    }

    func resolveBest(providedUrl: URL, token: String) async throws -> RegionInfo {
        try await requestSettingsIfNeeded(providedUrl: providedUrl, token: token)
        guard let selected = state.remaining.first else {
            throw LiveKitError(.regionUrlProvider, message: "No more remaining regions.")
        }

        log("[Region] Resolved region: \(String(describing: selected))", .debug)
        return selected
    }

    func updateFromServerReportedRegions(_ regions: Livekit_RegionSettings, providedUrl: URL) {
        guard providedUrl.isCloud else { return }

        let allRegions = regions.regions.compactMap { $0.toLKType() }
        guard !allRegions.isEmpty else { return }

        // Preserve previously failed regions while updating the server-provided region list.
        let allIds = Set(state.all.map(\.regionId))
        let remainingIds = Set(state.remaining.map(\.regionId))
        let failedRegionIds = allIds.subtracting(remainingIds)

        let remainingRegions = allRegions.filter { !failedRegionIds.contains($0.regionId) }
        log("[Region] Updating regions from server-reported settings (\(allRegions.count)), remaining: \(remainingRegions.count)", .info)

        state.url = providedUrl
        state.all = allRegions
        state.remaining = remainingRegions
        state.lastRequested = Date()
    }

    // MARK: - Testing

    func snapshot() -> State { state }

    func setStateForTesting(_ state: State) {
        self.state = state
    }

    // MARK: - Private

    private func startSettingsFetchIfNeeded(providedUrl: URL, token: String) {
        if let task = settingsFetchTask {
            return
        }

        let taskID = UUID()
        settingsFetchTaskID = taskID

        let task = Task { [providedUrl, token, taskID] in
            do {
                let data = try await Self.fetchRegionSettings(providedUrl: providedUrl, token: token)
                let allRegions = try Self.parseRegionSettings(data: data)
                await self.applyFetchedRegions(allRegions, providedUrl: providedUrl)
                await self.clearSettingsFetchTask(if: taskID)
            } catch {
                await self.log("[Region] Failed to fetch region settings: \(error)", .error)
                await self.clearSettingsFetchTask(if: taskID)
                throw error
            }
        }

        settingsFetchTask = task

        Task { [weak self] in
            _ = try? await task.value
            // If the task failed before it could clear itself.
            await self?.clearSettingsFetchTask(if: taskID)
        }
    }

    private func requestSettingsIfNeeded(providedUrl: URL, token: String) async throws {
        guard providedUrl.isCloud else {
            throw LiveKitError(.onlyForCloud)
        }

        guard shouldRequestSettings(for: providedUrl) else { return }
        startSettingsFetchIfNeeded(providedUrl: providedUrl, token: token)
        if let task = settingsFetchTask {
            try await task.value
        }
    }

    private func applyFetchedRegions(_ allRegions: [RegionInfo], providedUrl: URL) {
        log("[Region] all regions: \(String(describing: allRegions))", .debug)
        state.url = providedUrl
        state.all = allRegions
        state.remaining = allRegions
        state.lastRequested = Date()
    }

    private func clearSettingsFetchTask(if taskID: UUID) {
        guard settingsFetchTaskID == taskID else { return }
        settingsFetchTaskID = nil
        settingsFetchTask = nil
    }

    // MARK: - Static helpers (non-isolated)

    private nonisolated static func fetchRegionSettings(providedUrl: URL, token: String) async throws -> Data {
        var request = URLRequest(url: providedUrl.regionSettingsUrl(),
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveKitError(.regionUrlProvider, message: "Failed to fetch region settings")
        }

        let statusCode = httpResponse.statusCode
        guard (200 ..< 300).contains(statusCode) else {
            let rawBody = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = if let rawBody, !rawBody.isEmpty {
                rawBody.count > 1024 ? String(rawBody.prefix(1024)) + "..." : rawBody
            } else {
                "(No server message)"
            }

            if (400 ..< 500).contains(statusCode) {
                throw LiveKitError(.validation, message: "Region settings error: HTTP \(statusCode): \(body)")
            }

            throw LiveKitError(.regionUrlProvider, message: "Failed to fetch region settings: HTTP \(statusCode): \(body)")
        }

        return data
    }

    private nonisolated static func parseRegionSettings(data: Data) throws -> [RegionInfo] {
        do {
            let regionSettings = try Livekit_RegionSettings(jsonUTF8Data: data)
            let allRegions = regionSettings.regions.compactMap { $0.toLKType() }
            guard !allRegions.isEmpty else {
                throw LiveKitError(.regionUrlProvider, message: "Fetched region data is empty.")
            }
            return allRegions
        } catch {
            throw LiveKitError(.regionUrlProvider, message: "Failed to parse region settings with error: \(error)")
        }
    }
}
