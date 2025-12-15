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

@testable import LiveKit
import XCTest

class RegionUrlProviderTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
    }

    func testResolveUrl() async throws {
        let room = Room()

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

        let providedUrl = URL(string: "https://example.livekit.cloud")!

        // See if request should be initiated.
        let shouldRequestInitially = await room.regionManager.shouldRequestSettings(for: providedUrl)
        XCTAssertTrue(shouldRequestInitially, "Should require to request region settings")

        await room.regionManager.setStateForTesting(.init(url: providedUrl,
                                                          lastRequested: Date(),
                                                          all: testRegionSettings,
                                                          remaining: testRegionSettings))

        // See if request is not required to be initiated.
        let shouldRequestAfterSeed = await room.regionManager.shouldRequestSettings(for: providedUrl)
        XCTAssertFalse(shouldRequestAfterSeed, "Should not require to request region settings")

        let attempt1 = try await room.regionManager.resolveBest(providedUrl: providedUrl, token: "")
        print("Next url: \(String(describing: attempt1))")
        XCTAssert(attempt1.url == testRegionSettings[0].url)
        await room.regionManager.markFailed(region: attempt1)

        let attempt2 = try await room.regionManager.resolveBest(providedUrl: providedUrl, token: "")
        print("Next url: \(String(describing: attempt2))")
        XCTAssert(attempt2.url == testRegionSettings[1].url)
        await room.regionManager.markFailed(region: attempt2)

        let attempt3 = try await room.regionManager.resolveBest(providedUrl: providedUrl, token: "")
        print("Next url: \(String(describing: attempt3))")
        XCTAssert(attempt3.url == testRegionSettings[2].url)
        await room.regionManager.markFailed(region: attempt3)

        // No more regions
        let attempt4 = try? await room.regionManager.resolveBest(providedUrl: providedUrl, token: "")
        XCTAssert(attempt4 == nil)

        // Simulate cache time elapse.
        let snapshot = await room.regionManager.snapshot()
        await room.regionManager.setStateForTesting(.init(url: snapshot.url,
                                                          lastRequested: Date().addingTimeInterval(-(RegionManager.cacheInterval + 1)),
                                                          all: snapshot.all,
                                                          remaining: snapshot.remaining))

        // After cache time elapsed, should require to request region settings again.
        let shouldRequestAfterCache = await room.regionManager.shouldRequestSettings(for: providedUrl)
        XCTAssertTrue(shouldRequestAfterCache, "Should require to request region settings")
    }

    func testIsCloud() {
        XCTAssertTrue(URL(string: "wss://test.livekit.cloud")!.isCloud)
        XCTAssertTrue(URL(string: "wss://test.livekit.run")!.isCloud)
        XCTAssertFalse(URL(string: "wss://self-hosted.example.com")!.isCloud)
        XCTAssertFalse(URL(string: "ws://localhost:7880")!.isCloud)
    }

    func testRegionSettingsUrlConversion() {
        XCTAssertEqual(URL(string: "wss://test.livekit.cloud")!.regionSettingsUrl().absoluteString,
                       "https://test.livekit.cloud/settings/regions")
        XCTAssertEqual(URL(string: "ws://test.livekit.cloud")!.regionSettingsUrl().absoluteString,
                       "http://test.livekit.cloud/settings/regions")
        XCTAssertEqual(URL(string: "https://test.livekit.cloud")!.regionSettingsUrl().absoluteString,
                       "https://test.livekit.cloud/settings/regions")
    }

    func testRegionManagerShouldRetryConnection() {
        XCTAssertTrue(LiveKitError(.network).isRetryableForRegionFailover)
        XCTAssertTrue(LiveKitError(.timedOut).isRetryableForRegionFailover)
        XCTAssertFalse(LiveKitError(.validation).isRetryableForRegionFailover)

        XCTAssertTrue(URLError(.timedOut).isRetryableForRegionFailover)
        XCTAssertTrue(NSError(domain: NSURLErrorDomain, code: -1).isRetryableForRegionFailover)
        XCTAssertFalse(NSError(domain: "other", code: -1).isRetryableForRegionFailover)
    }

    func testFetchRegionSettingsClassifies4xxAsValidation() async {
        let room = Room()
        let providedUrl = URL(string: "https://example.livekit.cloud")!

        MockURLProtocol.allowedHosts = [providedUrl.host!]
        MockURLProtocol.allowedPaths = ["/settings/regions"]
        MockURLProtocol.requestHandler = { _ in
            .init(statusCode: 404, headers: [:], body: Data("not found".utf8))
        }
        URLProtocol.registerClass(MockURLProtocol.self)

        do {
            _ = try await room.regionManager.resolveBest(providedUrl: providedUrl, token: "token")
            XCTFail("Expected to throw")
        } catch {
            guard let liveKitError = error as? LiveKitError else {
                XCTFail("Expected LiveKitError, got \(error)")
                return
            }
            XCTAssertEqual(liveKitError.type, .validation)
        }
    }

    func testFetchRegionSettingsClassifies5xxAsRegionUrlProvider() async {
        let room = Room()
        let providedUrl = URL(string: "https://example.livekit.cloud")!

        MockURLProtocol.allowedHosts = [providedUrl.host!]
        MockURLProtocol.allowedPaths = ["/settings/regions"]
        MockURLProtocol.requestHandler = { _ in
            .init(statusCode: 500, headers: [:], body: Data("server error".utf8))
        }
        URLProtocol.registerClass(MockURLProtocol.self)

        do {
            _ = try await room.regionManager.resolveBest(providedUrl: providedUrl, token: "token")
            XCTFail("Expected to throw")
        } catch {
            guard let liveKitError = error as? LiveKitError else {
                XCTFail("Expected LiveKitError, got \(error)")
                return
            }
            XCTAssertEqual(liveKitError.type, .regionUrlProvider)
        }
    }

    func testFetchRegionSettingsParsesRegions() async throws {
        let room = Room()
        let providedUrl = URL(string: "https://example.livekit.cloud")!

        let body = Data("""
        {
          "regions": [
            { "region": "a", "url": "https://regiona.livekit.cloud", "distance": "100" },
            { "region": "b", "url": "https://regionb.livekit.cloud", "distance": "200" }
          ]
        }
        """.utf8)

        MockURLProtocol.allowedHosts = [providedUrl.host!]
        MockURLProtocol.allowedPaths = ["/settings/regions"]
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer token")
            return .init(statusCode: 200, headers: [:], body: body)
        }
        URLProtocol.registerClass(MockURLProtocol.self)

        let region = try await room.regionManager.resolveBest(providedUrl: providedUrl, token: "token")
        XCTAssertEqual(region.regionId, "a")

        let state = await room.regionManager.snapshot()
        XCTAssertEqual(state.all.count, 2)
        XCTAssertEqual(state.remaining.count, 2)
        XCTAssertEqual(state.url, providedUrl)
    }

    func testUpdateFromServerReportedRegionsPreservesFailedRegions() async {
        let room = Room()
        let providedUrl = URL(string: "https://example.livekit.cloud")!

        let a = RegionInfo(region: "a", url: "https://regiona.livekit.cloud", distance: 100)!
        let b = RegionInfo(region: "b", url: "https://regionb.livekit.cloud", distance: 200)!
        let c = RegionInfo(region: "c", url: "https://regionc.livekit.cloud", distance: 300)!

        await room.regionManager.setStateForTesting(.init(url: providedUrl,
                                                          lastRequested: Date(),
                                                          all: [a, b, c],
                                                          remaining: [a, c]))

        let serverRegions = Livekit_RegionSettings.with {
            $0.regions = [
                .with { $0.region = "a"; $0.url = a.url.absoluteString; $0.distance = a.distance },
                .with { $0.region = "b"; $0.url = b.url.absoluteString; $0.distance = b.distance },
                .with { $0.region = "c"; $0.url = c.url.absoluteString; $0.distance = c.distance },
            ]
        }

        await room.regionManager.updateFromServerReportedRegions(serverRegions, providedUrl: providedUrl)

        let updated = await room.regionManager.snapshot()
        XCTAssertEqual(updated.all.map(\.regionId), ["a", "b", "c"])
        XCTAssertEqual(updated.remaining.map(\.regionId), ["a", "c"])
    }
}
