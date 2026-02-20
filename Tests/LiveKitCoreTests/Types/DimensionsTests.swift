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

class DimensionsTests: LKTestCase {
    // MARK: - Basic Properties

    func testAspectRatioLandscape() {
        let dims = Dimensions(width: 1920, height: 1080)
        XCTAssertEqual(dims.aspectRatio, 16.0 / 9.0, accuracy: 0.01)
    }

    func testAspectRatioPortrait() {
        let dims = Dimensions(width: 1080, height: 1920)
        // aspectRatio always returns larger/smaller
        XCTAssertEqual(dims.aspectRatio, 16.0 / 9.0, accuracy: 0.01)
    }

    func testAspectRatioSquare() {
        let dims = Dimensions(width: 100, height: 100)
        XCTAssertEqual(dims.aspectRatio, 1.0, accuracy: 0.001)
    }

    func testAspectRatio43() {
        let dims = Dimensions(width: 640, height: 480)
        XCTAssertEqual(dims.aspectRatio, 4.0 / 3.0, accuracy: 0.01)
    }

    func testMax() {
        XCTAssertEqual(Dimensions(width: 1920, height: 1080).max, 1920)
        XCTAssertEqual(Dimensions(width: 1080, height: 1920).max, 1920)
        XCTAssertEqual(Dimensions(width: 500, height: 500).max, 500)
    }

    func testArea() {
        XCTAssertEqual(Dimensions(width: 1920, height: 1080).area, 1920 * 1080)
        XCTAssertEqual(Dimensions(width: 0, height: 100).area, 0)
    }

    // MARK: - Swapped

    func testSwapped() {
        let dims = Dimensions(width: 1920, height: 1080)
        let swapped = dims.swapped()
        XCTAssertEqual(swapped.width, 1080)
        XCTAssertEqual(swapped.height, 1920)
    }

    func testSwappedSquare() {
        let dims = Dimensions(width: 100, height: 100)
        let swapped = dims.swapped()
        XCTAssertEqual(swapped.width, 100)
        XCTAssertEqual(swapped.height, 100)
    }

    // MARK: - AspectFit

    func testAspectFitLandscape() {
        let dims = Dimensions(width: 1920, height: 1080)
        let fitted = dims.aspectFit(size: 1280)
        // Landscape: width >= height, so width becomes size, height scales proportionally
        XCTAssertEqual(fitted.width, 1280)
        XCTAssertEqual(fitted.height, Int32(Double(1080) / Double(1920) * 1280))
    }

    func testAspectFitPortrait() {
        let dims = Dimensions(width: 1080, height: 1920)
        let fitted = dims.aspectFit(size: 1280)
        // Portrait: height > width, so height becomes size, width scales proportionally
        XCTAssertEqual(fitted.height, 1280)
        XCTAssertEqual(fitted.width, Int32(Double(1080) / Double(1920) * 1280))
    }

    func testAspectFitSquare() {
        let dims = Dimensions(width: 500, height: 500)
        let fitted = dims.aspectFit(size: 200)
        XCTAssertEqual(fitted.width, 200)
        XCTAssertEqual(fitted.height, 200)
    }

    // MARK: - Preset Selection

    func testComputeSuggestedPresetsScreenShare() {
        let dims = Dimensions(width: 1920, height: 1080)
        let presets = dims.computeSuggestedPresets(isScreenShare: true)
        XCTAssertEqual(presets, VideoParameters.presetsScreenShare)
    }

    func testComputeSuggestedPresets169() {
        let dims = Dimensions(width: 1920, height: 1080)
        let presets = dims.computeSuggestedPresets(isScreenShare: false)
        XCTAssertEqual(presets, VideoParameters.presets169)
    }

    func testComputeSuggestedPresets43() {
        let dims = Dimensions(width: 640, height: 480)
        let presets = dims.computeSuggestedPresets(isScreenShare: false)
        XCTAssertEqual(presets, VideoParameters.presets43)
    }

    func testComputeSuggestedPresetMatchesResolution() {
        // 720p should select the 720p preset encoding
        let dims = Dimensions(width: 1280, height: 720)
        let encoding = dims.computeSuggestedPreset(in: VideoParameters.presets169)
        XCTAssertEqual(encoding, VideoParameters.presetH720_169.encoding)
    }

    func testComputeSuggestedPresetSmallResolution() {
        // Very small resolution should get the first (smallest) preset
        let dims = Dimensions(width: 100, height: 56)
        let encoding = dims.computeSuggestedPreset(in: VideoParameters.presets169)
        XCTAssertEqual(encoding, VideoParameters.presetH90_169.encoding)
    }

    func testComputeSuggestedPresetLargeResolution() {
        // Very large resolution should get the last (largest) preset
        let dims = Dimensions(width: 5000, height: 2812)
        let encoding = dims.computeSuggestedPreset(in: VideoParameters.presets169)
        XCTAssertEqual(encoding, VideoParameters.presetH2160_169.encoding)
    }

    // MARK: - Equality and Hashing

    func testEquality() {
        let a = Dimensions(width: 1920, height: 1080)
        let b = Dimensions(width: 1920, height: 1080)
        let c = Dimensions(width: 1080, height: 1920)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testHashing() {
        let a = Dimensions(width: 1920, height: 1080)
        let b = Dimensions(width: 1920, height: 1080)
        XCTAssertEqual(a.hash, b.hash)

        // Different dimensions should (likely) have different hashes
        let c = Dimensions(width: 1080, height: 1920)
        XCTAssertNotEqual(a.hash, c.hash)
    }

    func testEqualityWithNonDimensionsObject() {
        let dims = Dimensions(width: 1920, height: 1080)
        XCTAssertFalse(dims.isEqual("not a Dimensions"))
        XCTAssertFalse(dims.isEqual(nil))
    }

    // MARK: - Static Constants

    func testZero() {
        XCTAssertEqual(Dimensions.zero.width, 0)
        XCTAssertEqual(Dimensions.zero.height, 0)
    }

    func testAspectRatioConstants() {
        XCTAssertEqual(Dimensions.aspectRatio169, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(Dimensions.aspectRatio43, 4.0 / 3.0, accuracy: 0.0001)
    }

    // MARK: - Presets

    func testPreset169Dimensions() {
        XCTAssertEqual(Dimensions.h90_169.width, 160)
        XCTAssertEqual(Dimensions.h90_169.height, 90)
        XCTAssertEqual(Dimensions.h720_169.width, 1280)
        XCTAssertEqual(Dimensions.h720_169.height, 720)
        XCTAssertEqual(Dimensions.h1080_169.width, 1920)
        XCTAssertEqual(Dimensions.h1080_169.height, 1080)
        XCTAssertEqual(Dimensions.h2160_169.width, 3840)
        XCTAssertEqual(Dimensions.h2160_169.height, 2160)
    }

    func testPreset43Dimensions() {
        XCTAssertEqual(Dimensions.h120_43.width, 160)
        XCTAssertEqual(Dimensions.h120_43.height, 120)
        XCTAssertEqual(Dimensions.h720_43.width, 960)
        XCTAssertEqual(Dimensions.h720_43.height, 720)
        XCTAssertEqual(Dimensions.h1440_43.width, 1920)
        XCTAssertEqual(Dimensions.h1440_43.height, 1440)
    }

    // MARK: - Description

    func testDescription() {
        let dims = Dimensions(width: 1920, height: 1080)
        XCTAssertEqual(dims.description, "Dimensions(1920x1080)")
    }

    // MARK: - Preset Arrays

    func testPresetsAreOrderedByResolution() {
        let presets169 = VideoParameters.presets169
        for i in 1 ..< presets169.count {
            XCTAssertGreaterThan(
                presets169[i].dimensions.width,
                presets169[i - 1].dimensions.width,
                "16:9 presets should be ordered by ascending width"
            )
        }

        let presets43 = VideoParameters.presets43
        for i in 1 ..< presets43.count {
            XCTAssertGreaterThan(
                presets43[i].dimensions.width,
                presets43[i - 1].dimensions.width,
                "4:3 presets should be ordered by ascending width"
            )
        }
    }

    func testPresetsHaveIncreasingBitrate() {
        let presets169 = VideoParameters.presets169
        for i in 1 ..< presets169.count {
            XCTAssertGreaterThan(
                presets169[i].encoding.maxBitrate,
                presets169[i - 1].encoding.maxBitrate,
                "16:9 presets should have increasing bitrate"
            )
        }
    }
}
