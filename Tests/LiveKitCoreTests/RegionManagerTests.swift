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
import LiveKitTestSupport
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
        }].map { $0.toLKType() }.compactMap { $0 }

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

        let attempt1 = try await regionManager.resolveBest(token: "")
        #expect(attempt1.url == testRegionSettings[0].url)
        await regionManager.markFailed(region: attempt1)

        let attempt2 = try await regionManager.resolveBest(token: "")
        #expect(attempt2.url == testRegionSettings[1].url)
        await regionManager.markFailed(region: attempt2)

        let attempt3 = try await regionManager.resolveBest(token: "")
        #expect(attempt3.url == testRegionSettings[2].url)
        await regionManager.markFailed(region: attempt3)

        // No more regions
        let attempt4 = try? await regionManager.resolveBest(token: "")
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

    @Test(arguments: [
        ("wss://test.livekit.cloud", true),
        ("wss://test.livekit.run", true),
        ("wss://self-hosted.example.com", false),
        ("ws://localhost:7880", false),
    ])
    func isCloud(urlString: String, expected: Bool) throws {
        let isCloud = try #require(URL(string: urlString)?.isCloud)
        #expect(isCloud == expected)
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

        do {
            _ = try await regionManager.resolveBest(token: "token")
            Issue.record("Expected error for status \(statusCode)")
        } catch let error as LiveKitError {
            #expect(error.type == expectedErrorType)
        } catch {
            Issue.record("Expected LiveKitError, got \(error)")
        }
    }
}
