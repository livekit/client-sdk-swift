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

@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import XCTest

class RegionManagerTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
    }

    func testResolveUrl() async throws {
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

        let providedUrl = try XCTUnwrap(URL(string: "https://example.livekit.cloud"))
        let regionManager = RegionManager(providedUrl: providedUrl)

        // See if request should be initiated.
        let shouldRequestInitially = await regionManager.shouldRequestSettings()
        XCTAssertTrue(shouldRequestInitially, "Should require to request region settings")

        await regionManager.setStateForTesting(.init(lastRequested: Date(),
                                                     all: testRegionSettings,
                                                     remaining: testRegionSettings))

        // See if request is not required to be initiated.
        let shouldRequestAfterSeed = await regionManager.shouldRequestSettings()
        XCTAssertFalse(shouldRequestAfterSeed, "Should not require to request region settings")

        let attempt1 = try await regionManager.resolveBest(token: "")
        XCTAssert(attempt1.url == testRegionSettings[0].url)
        await regionManager.markFailed(region: attempt1)

        let attempt2 = try await regionManager.resolveBest(token: "")
        XCTAssert(attempt2.url == testRegionSettings[1].url)
        await regionManager.markFailed(region: attempt2)

        let attempt3 = try await regionManager.resolveBest(token: "")
        XCTAssert(attempt3.url == testRegionSettings[2].url)
        await regionManager.markFailed(region: attempt3)

        // No more regions
        let attempt4 = try? await regionManager.resolveBest(token: "")
        XCTAssert(attempt4 == nil)

        // Simulate cache time elapse.
        let snapshot = await regionManager.snapshot()
        await regionManager.setStateForTesting(.init(lastRequested: Date().addingTimeInterval(-(RegionManager.cacheInterval + 1)),
                                                     all: snapshot.all,
                                                     remaining: snapshot.remaining))

        // After cache time elapsed, should require to request region settings again.
        let shouldRequestAfterCache = await regionManager.shouldRequestSettings()
        XCTAssertTrue(shouldRequestAfterCache, "Should require to request region settings")
    }

    func testIsCloud() throws {
        XCTAssertTrue(try XCTUnwrap(URL(string: "wss://test.livekit.cloud")?.isCloud))
        XCTAssertTrue(try XCTUnwrap(URL(string: "wss://test.livekit.run")?.isCloud))
        XCTAssertFalse(try XCTUnwrap(URL(string: "wss://self-hosted.example.com")?.isCloud))
        XCTAssertFalse(try XCTUnwrap(URL(string: "ws://localhost:7880")?.isCloud))
    }

    func testRegionSettingsUrlConversion() {
        XCTAssertEqual(URL(string: "wss://test.livekit.cloud")?.regionSettingsUrl().absoluteString,
                       "https://test.livekit.cloud/settings/regions")
        XCTAssertEqual(URL(string: "ws://test.livekit.cloud")?.regionSettingsUrl().absoluteString,
                       "http://test.livekit.cloud/settings/regions")
        XCTAssertEqual(URL(string: "https://test.livekit.cloud")?.regionSettingsUrl().absoluteString,
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

    func testFetchRegionSettingsClassifies4xxAsValidation() async throws {
        let providedUrl = try XCTUnwrap(URL(string: "https://example.livekit.cloud"))
        let regionManager = RegionManager(providedUrl: providedUrl)

        try MockURLProtocol.setAllowedHosts([XCTUnwrap(providedUrl.host)])
        MockURLProtocol.setAllowedPaths(["/settings/regions"])
        MockURLProtocol.setRequestHandler { (_: URLRequest) in
            MockURLProtocol.Response(statusCode: 401,
                                     headers: [:],
                                     body: Data("not allowed".utf8))
        }
        URLProtocol.registerClass(MockURLProtocol.self)

        do {
            _ = try await regionManager.resolveBest(token: "token")
            XCTFail("Expected error")
        } catch let error as LiveKitError {
            XCTAssertEqual(error.type, .validation)
        } catch {
            XCTFail("Expected LiveKitError, got \(error)")
        }
    }

    func testFetchRegionSettingsClassifies5xxAsRegionManagerError() async throws {
        let providedUrl = try XCTUnwrap(URL(string: "https://example.livekit.cloud"))
        let regionManager = RegionManager(providedUrl: providedUrl)

        try MockURLProtocol.setAllowedHosts([XCTUnwrap(providedUrl.host)])
        MockURLProtocol.setAllowedPaths(["/settings/regions"])
        MockURLProtocol.setRequestHandler { (_: URLRequest) in
            MockURLProtocol.Response(statusCode: 500,
                                     headers: [:],
                                     body: Data("server error".utf8))
        }
        URLProtocol.registerClass(MockURLProtocol.self)

        do {
            _ = try await regionManager.resolveBest(token: "token")
            XCTFail("Expected error")
        } catch let error as LiveKitError {
            XCTAssertEqual(error.type, .regionManager)
        } catch {
            XCTFail("Expected LiveKitError, got \(error)")
        }
    }
}
