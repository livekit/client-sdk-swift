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

@testable import LiveKit
import XCTest

class RegionUrlProviderTests: XCTestCase {
    func testResolveUrl() async throws {
        let testCacheInterval: TimeInterval = 3
        // Test data.
        let testRegionSettings = Livekit_RegionSettings.with {
            $0.regions.append(Livekit_RegionInfo.with {
                $0.region = "otokyo1a"
                $0.url = "https://example.otokyo1a.production.livekit.cloud"
                $0.distance = 32838
            })
            $0.regions.append(Livekit_RegionInfo.with {
                $0.region = "dblr1a"
                $0.url = "https://example.dblr1a.production.livekit.cloud"
                $0.distance = 6_660_301
            })
            $0.regions.append(Livekit_RegionInfo.with {
                $0.region = "dsyd1a"
                $0.url = "https://example.dsyd1a.production.livekit.cloud"
                $0.distance = 7_823_582
            })
        }

        let provider = RegionUrlProvider(url: "wss://test.livekit.cloud", token: "", cacheInterval: testCacheInterval)

        // See if request should be initiated.
        XCTAssert(provider.shouldRequestRegionSettings(), "Should require to request region settings")

        // Set test data.
        provider.set(regionSettings: testRegionSettings)

        // See if request is not required to be initiated.
        XCTAssert(!provider.shouldRequestRegionSettings(), "Should require to request region settings")

        let attempt1 = try await provider.nextBestRegionUrl()
        print("Next url: \(String(describing: attempt1))")
        XCTAssert(attempt1?.absoluteString == testRegionSettings.regions[0].url)

        let attempt2 = try await provider.nextBestRegionUrl()
        print("Next url: \(String(describing: attempt2))")
        XCTAssert(attempt2?.absoluteString == testRegionSettings.regions[1].url)

        let attempt3 = try await provider.nextBestRegionUrl()
        print("Next url: \(String(describing: attempt3))")
        XCTAssert(attempt3?.absoluteString == testRegionSettings.regions[2].url)

        let attempt4 = try await provider.nextBestRegionUrl()
        print("Next url: \(String(describing: attempt4))")
        XCTAssert(attempt4 == nil)

        // Simulate cache time elapse.
        await asyncSleep(for: testCacheInterval)

        // After cache time elapsed, should require to request region settings again.
        XCTAssert(provider.shouldRequestRegionSettings(), "Should require to request region settings")
    }
}
