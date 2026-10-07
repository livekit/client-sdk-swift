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
@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import Testing

@Suite(.serialized, .tags(.networking)) struct RegionManagerTests {
    private func cleanUpMockURLProtocol() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
    }

    @Test func resolveUrl() async throws {
        // Test data.
        let testRegionSettings = [Livekit_RegionInfo.with {
            $0.region = "otokyo1a"
            $0.url = "https://example.otokyo1a.production.livekit.cloud"
            $0.distance = 32838
        },
        Livekit_RegionInfo.with {
            $0.region = "dblr1a"
            $0.url = "https://example.dblr1a.production.livekit.cloud"
            $0.distance = 6_660_301
        },
        Livekit_RegionInfo.with {
            $0.region = "dsyd1a"
            $0.url = "https://example.dsyd1a.production.livekit.cloud"
            $0.distance = 7_823_582
        }].map { $0.toLKType() }.compactMap(\.self)

        let providedUrl = try #require(URL(string: "https://example.livekit.cloud"))
        let regionManager = RegionManager(providedUrl: providedUrl)

        // See if request should be initiated.
        let shouldRequestInitially = await regionManager.shouldRequestSettings()
        #expect(shouldRequestInitially, "Should require to request region settings")

        await regionManager.setStateForTesting(.init(lastRequested: Date(),
                                                     all: testRegionSettings,
                                                     remaining: testRegionSettings))

        // See if request is not required to be initiated.
        let shouldRequestAfterSeed = await regionManager.shouldRequestSettings()
        #expect(!shouldRequestAfterSeed, "Should not require to request region settings")

        let attempt1 = try #require(await regionManager.resolveBest(token: ""))
        #expect(attempt1.url == testRegionSettings[0].url)
        await regionManager.markFailed(region: attempt1)

        let attempt2 = try #require(await regionManager.resolveBest(token: ""))
        #expect(attempt2.url == testRegionSettings[1].url)
        await regionManager.markFailed(region: attempt2)

        let attempt3 = try #require(await regionManager.resolveBest(token: ""))
        #expect(attempt3.url == testRegionSettings[2].url)
        await regionManager.markFailed(region: attempt3)

        // Exhaustion is a nil result, not an error — the failover loop tells it apart from a
        // settings fetch failure so it can rethrow the connection error instead.
        let attempt4 = try await regionManager.resolveBest(token: "")
        #expect(attempt4 == nil)

        // Simulate cache time elapse.
        let snapshot = await regionManager.snapshot()
        await regionManager.setStateForTesting(.init(lastRequested: Date().addingTimeInterval(-(RegionManager.cacheInterval + 1)),
                                                     all: snapshot.all,
                                                     remaining: snapshot.remaining))

        // After cache time elapsed, should require to request region settings again.
        let shouldRequestAfterCache = await regionManager.shouldRequestSettings()
        #expect(shouldRequestAfterCache, "Should require to request region settings")
    }

    /// A settings refresh must not resurrect regions that already failed. Per-region failure can
    /// outlast `cacheInterval`, and if the refresh refilled `remaining` the failover loop would
    /// get a region back for every one it marked failed and never terminate.
    @Test func refreshKeepsFailedRegionsExcluded() async throws {
        let reported = [Livekit_RegionInfo.with {
            $0.region = "otokyo1a"
            $0.url = "https://example.otokyo1a.production.livekit.cloud"
            $0.distance = 32838
        },
        Livekit_RegionInfo.with {
            $0.region = "dblr1a"
            $0.url = "https://example.dblr1a.production.livekit.cloud"
            $0.distance = 6_660_301
        }]
        let regions = reported.map { $0.toLKType() }.compactMap(\.self)

        let providedUrl = try #require(URL(string: "https://example.livekit.cloud"))
        let regionManager = RegionManager(providedUrl: providedUrl)
        await regionManager.setStateForTesting(.init(lastRequested: Date(),
                                                     all: regions,
                                                     remaining: regions))

        let first = try #require(await regionManager.resolveBest(token: ""))
        await regionManager.markFailed(region: first)

        // The same list arriving again stands in for a refresh landing mid-failover.
        await regionManager.updateFromServerReportedRegions(.with { $0.regions = reported })

        let remaining = await regionManager.snapshot().remaining
        #expect(!remaining.contains { $0.regionId == first.regionId },
                "A refresh must not put a failed region back in the remaining list")
        #expect(remaining.count == regions.count - 1)
    }

    @Test(arguments: [
        ("wss://test.livekit.cloud", true),
        ("wss://test.livekit.run", true),
        ("wss://self-hosted.example.com", false),
        ("ws://localhost:7880", false),
    ])
    func isCloud(urlString: String, expected: Bool) throws {
        let url = try #require(URL(string: urlString))
        #expect(url.isCloud == expected)
    }

    @Test(arguments: [
        ("wss://test.livekit.cloud", "https://test.livekit.cloud/settings/regions"),
        ("ws://test.livekit.cloud", "http://test.livekit.cloud/settings/regions"),
        ("https://test.livekit.cloud", "https://test.livekit.cloud/settings/regions"),
    ])
    func regionSettingsUrlConversion(input: String, expected: String) {
        #expect(URL(string: input)?.regionSettingsUrl().absoluteString == expected)
    }

    @Test func regionManagerShouldRetryConnection() {
        #expect(LiveKitError(.network).isRetryableForRegionFailover)
        #expect(LiveKitError(.timedOut).isRetryableForRegionFailover)
        #expect(!LiveKitError(.validation).isRetryableForRegionFailover)

        #expect(URLError(.timedOut).isRetryableForRegionFailover)
        #expect(NSError(domain: NSURLErrorDomain, code: -1).isRetryableForRegionFailover)
        #expect(!NSError(domain: "other", code: -1).isRetryableForRegionFailover)
    }

    /// LiveKit Cloud signals project-level region pinning with a 403 on the RTC paths. It arrives
    /// as `.validation`, which is otherwise terminal, so failover has to admit it on the status —
    /// otherwise a client that geo-routes to a disallowed region never reaches its allowed one.
    @Test func regionPinning403IsRetryableButOtherValidationFailuresAreNot() {
        #expect(LiveKitError(.validation,
                             message: "project not allowed in this region.",
                             statusCode: 403).isRetryableForRegionFailover)

        // No other region will accept a token this one rejected.
        #expect(!LiveKitError(.validation, message: "unauthorized", statusCode: 401).isRetryableForRegionFailover)
        // The v1 → v0 RTC path fallback owns this one; it is not a region problem.
        #expect(!LiveKitError(.serviceNotFound, message: "not found", statusCode: 404).isRetryableForRegionFailover)
        // The status only discriminates within the type it belongs to; a 403 recorded on any
        // other type must not opt itself into failover.
        #expect(!LiveKitError(.serviceNotFound, message: "not found", statusCode: 403).isRetryableForRegionFailover)
        #expect(!LiveKitError(.cancelled, message: "stopped", statusCode: 403).isRetryableForRegionFailover)
    }

    /// Without this the whole feature can be removed by deleting one argument at the throw site:
    /// `regionPinning403IsRetryableButOtherValidationFailuresAreNot` builds its errors by hand, so
    /// it stays green even if `requestValidation` stops recording the status.
    ///
    /// Goes through the local server rather than `MockURLProtocol`, which only intercepts
    /// `URLSession.shared` and so cannot see `HTTP`'s own session.
    @Test func validationErrorCarriesTheHttpStatus() async throws {
        let serverUrl = try #require(URL(string: TestEnvironment.liveKitServerUrl()))
        let validateUrl = try #require(URL(string: "/rtc/validate", relativeTo: serverUrl.toHTTPUrl())?.absoluteURL)

        await #expect {
            try await HTTP.requestValidation(from: validateUrl, token: "not-a-token")
        } throws: { error in
            guard let lkError = error as? LiveKitError else { return false }
            return lkError.type == .validation && lkError.statusCode == 401
        }
    }

    /// Same invariant as `refreshKeepsFailedRegionsExcluded`, but through the path a real refresh
    /// takes: the settings *fetch*, which lands in `applyFetchedRegions`. The sibling test drives
    /// `updateFromServerReportedRegions`, which already excluded failed regions before this change.
    @Test func fetchedRefreshKeepsFailedRegionsExcluded() async throws {
        let providedUrl = try #require(URL(string: "https://example.livekit.cloud"))
        let regionManager = RegionManager(providedUrl: providedUrl)

        try MockURLProtocol.setAllowedHosts([#require(providedUrl.host)])
        MockURLProtocol.setAllowedPaths(["/settings/regions"])
        MockURLProtocol.setRequestHandler { (_: URLRequest) in
            MockURLProtocol.Response(statusCode: 200, headers: [:], body: Data("""
            {"regions": [
                {"region": "otokyo1a", "url": "https://example.otokyo1a.livekit.cloud", "distance": "1"},
                {"region": "dblr1a", "url": "https://example.dblr1a.livekit.cloud", "distance": "2"}
            ]}
            """.utf8))
        }
        URLProtocol.registerClass(MockURLProtocol.self)
        defer { cleanUpMockURLProtocol() }

        let first = try #require(await regionManager.resolveBest(token: "token"))
        await regionManager.markFailed(region: first)

        // Rewind the cache so the next resolve refetches, as it would when per-region failure
        // outlasts `cacheInterval`.
        let snapshot = await regionManager.snapshot()
        await regionManager.setStateForTesting(.init(lastRequested: Date().addingTimeInterval(-(RegionManager.cacheInterval + 1)),
                                                     all: snapshot.all,
                                                     remaining: snapshot.remaining))

        let second = try #require(await regionManager.resolveBest(token: "token"))
        #expect(second.regionId != first.regionId,
                "A fetched refresh must not put a failed region back at the head of the list")
    }

    @Test(arguments: [
        (401, LiveKitErrorType.validation),
        (500, LiveKitErrorType.regionManager),
    ])
    func fetchRegionSettingsClassifiesHttpErrors(statusCode: Int, expectedErrorType: LiveKitErrorType) async throws {
        let providedUrl = try #require(URL(string: "https://example.livekit.cloud"))
        let regionManager = RegionManager(providedUrl: providedUrl)

        try MockURLProtocol.setAllowedHosts([#require(providedUrl.host)])
        MockURLProtocol.setAllowedPaths(["/settings/regions"])
        MockURLProtocol.setRequestHandler { (_: URLRequest) in
            MockURLProtocol.Response(statusCode: statusCode,
                                     headers: [:],
                                     body: Data("error".utf8))
        }
        URLProtocol.registerClass(MockURLProtocol.self)
        defer { cleanUpMockURLProtocol() }

        await #expect {
            try await regionManager.resolveBest(token: "token")
        } throws: { error in
            guard let lkError = error as? LiveKitError else { return false }
            return lkError.type == expectedErrorType
        }
    }
}
