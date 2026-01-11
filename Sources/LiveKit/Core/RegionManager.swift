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

// MARK: - RegionManager

actor RegionManager: Loggable {
    struct State: Sendable {
        var lastRequested: Date?
        var all: [RegionInfo] = []
        var remaining: [RegionInfo] = []
    }

    static let cacheInterval: TimeInterval = 30

    nonisolated let providedUrl: URL
    private var state = State()
    private var settingsFetchTask: Task<[RegionInfo], Error>?
    private var settingsFetchTaskId: UUID?

    init(providedUrl: URL) {
        self.providedUrl = providedUrl
    }

    func cancel() {
        settingsFetchTask?.cancel()
        settingsFetchTask = nil
        settingsFetchTaskId = nil
    }

    func resetAttempts(onlyIfExhausted: Bool = false) {
        if onlyIfExhausted {
            guard state.remaining.isEmpty else { return }
        }
        guard !state.all.isEmpty else { return }
        state.remaining = state.all
    }

    func resetAll() {
        state = State()
    }

    func markFailed(region: RegionInfo) {
        state.remaining.removeAll { $0 == region }
    }

    func shouldRequestSettings() -> Bool {
        guard providedUrl.isCloud else { return false }
        guard let lastRequested = state.lastRequested else { return true }
        return Date().timeIntervalSince(lastRequested) > Self.cacheInterval
    }

    func prepareSettingsFetch(token: String) {
        guard shouldRequestSettings() else { return }
        _ = startSettingsFetchIfNeeded(token: token)
    }

    func resolveBest(token: String) async throws -> RegionInfo {
        try await requestSettingsIfNeeded(token: token)
        guard let selected = state.remaining.first else {
            throw LiveKitError(.regionManager, message: "No more remaining regions.")
        }

        log("[Region] Resolved region: \(String(describing: selected))", .debug)
        return selected
    }

    func updateFromServerReportedRegions(_ regions: Livekit_RegionSettings) {
        guard providedUrl.isCloud else { return }

        let allRegions = regions.regions.compactMap { $0.toLKType() }
        guard !allRegions.isEmpty else { return }

        // Keep previously failed regions excluded when updating the list.
        let allIds = Set(state.all.map(\.regionId))
        let remainingIds = Set(state.remaining.map(\.regionId))
        let failedRegionIds = allIds.subtracting(remainingIds)

        let remainingRegions = allRegions.filter { !failedRegionIds.contains($0.regionId) }
        log("[Region] Updating regions from server-reported settings (\(allRegions.count)), remaining: \(remainingRegions.count)", .info)

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

    private func startSettingsFetchIfNeeded(token: String) -> Task<[RegionInfo], Error> {
        if let task = settingsFetchTask { return task }

        let taskId = UUID()
        settingsFetchTaskId = taskId

        let task = Task { [providedUrl, token, taskId] in
            defer { clearSettingsFetchTask(matching: taskId) }
            do {
                let data = try await Self.fetchRegionSettings(providedUrl: providedUrl, token: token)
                let allRegions = try Self.parseRegionSettings(data: data)
                try Task.checkCancellation()
                applyFetchedRegions(allRegions)
                return allRegions
            } catch {
                log("[Region] Failed to fetch region settings: \(error)", .error)
                throw error
            }
        }

        settingsFetchTask = task
        return task
    }

    private func requestSettingsIfNeeded(token: String) async throws {
        guard providedUrl.isCloud else {
            throw LiveKitError(.onlyForCloud)
        }

        guard shouldRequestSettings() else { return }
        let task = startSettingsFetchIfNeeded(token: token)
        _ = try await task.value
    }

    private func applyFetchedRegions(_ allRegions: [RegionInfo]) {
        log("[Region] all regions: \(String(describing: allRegions))", .debug)
        state.all = allRegions
        state.remaining = allRegions
        state.lastRequested = Date()
    }

    private func clearSettingsFetchTask(matching taskId: UUID) {
        guard settingsFetchTaskId == taskId else { return }
        settingsFetchTaskId = nil
        settingsFetchTask = nil
    }

    // MARK: - Static helpers (non-isolated)

    private nonisolated static func fetchRegionSettings(providedUrl: URL, token: String) async throws -> Data {
        var request = URLRequest(url: providedUrl.regionSettingsUrl(),
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveKitError(.regionManager, message: "Failed to fetch region settings")
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

            throw LiveKitError(.regionManager, message: "Failed to fetch region settings: HTTP \(statusCode): \(body)")
        }

        return data
    }

    private nonisolated static func parseRegionSettings(data: Data) throws -> [RegionInfo] {
        do {
            let regionSettings = try Livekit_RegionSettings(jsonUTF8Data: data)
            let allRegions = regionSettings.regions.compactMap { $0.toLKType() }
            guard !allRegions.isEmpty else {
                throw LiveKitError(.regionManager, message: "Fetched region data is empty.")
            }
            return allRegions
        } catch {
            throw LiveKitError(.regionManager, message: "Failed to parse region settings with error: \(error)")
        }
    }
}
