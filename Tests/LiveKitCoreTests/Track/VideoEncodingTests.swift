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

class VideoEncodingTests: LKTestCase {
    // MARK: - Preset Selection by Aspect Ratio

    func testPresetSelection169Landscape() {
        let dims = Dimensions(width: 1920, height: 1080)
        let presets = dims.computeSuggestedPresets(isScreenShare: false)
        XCTAssertEqual(presets, VideoParameters.presets169)
    }

    func testPresetSelection169Portrait() {
        // Portrait 9:16 should still use 16:9 presets (aspectRatio is max/min)
        let dims = Dimensions(width: 1080, height: 1920)
        let presets = dims.computeSuggestedPresets(isScreenShare: false)
        XCTAssertEqual(presets, VideoParameters.presets169)
    }

    func testPresetSelection43() {
        let dims = Dimensions(width: 640, height: 480)
        let presets = dims.computeSuggestedPresets(isScreenShare: false)
        XCTAssertEqual(presets, VideoParameters.presets43)
    }

    func testPresetSelectionScreenShare() {
        let dims = Dimensions(width: 1920, height: 1080)
        let presets = dims.computeSuggestedPresets(isScreenShare: true)
        XCTAssertEqual(presets, VideoParameters.presetsScreenShare)
    }

    // MARK: - Encoding Selection by Resolution

    func testEncodingFor720p() {
        let dims = Dimensions(width: 1280, height: 720)
        let encoding = dims.computeSuggestedPreset(in: VideoParameters.presets169)
        XCTAssertEqual(encoding.maxBitrate, VideoParameters.presetH720_169.encoding.maxBitrate)
        XCTAssertEqual(encoding.maxFps, VideoParameters.presetH720_169.encoding.maxFps)
    }

    func testEncodingFor1080p() {
        let dims = Dimensions(width: 1920, height: 1080)
        let encoding = dims.computeSuggestedPreset(in: VideoParameters.presets169)
        XCTAssertEqual(encoding.maxBitrate, VideoParameters.presetH1080_169.encoding.maxBitrate)
    }

    func testEncodingFor360p() {
        let dims = Dimensions(width: 640, height: 360)
        let encoding = dims.computeSuggestedPreset(in: VideoParameters.presets169)
        XCTAssertEqual(encoding.maxBitrate, VideoParameters.presetH360_169.encoding.maxBitrate)
    }

    func testEncodingForVerySmallResolution() {
        let dims = Dimensions(width: 80, height: 45)
        let encoding = dims.computeSuggestedPreset(in: VideoParameters.presets169)
        // Smaller than smallest preset → gets first preset
        XCTAssertEqual(encoding.maxBitrate, VideoParameters.presetH90_169.encoding.maxBitrate)
    }

    func testEncodingForVeryLargeResolution() {
        let dims = Dimensions(width: 5120, height: 2880)
        let encoding = dims.computeSuggestedPreset(in: VideoParameters.presets169)
        // Larger than largest preset → gets last preset
        XCTAssertEqual(encoding.maxBitrate, VideoParameters.presetH2160_169.encoding.maxBitrate)
    }

    // MARK: - VideoParameters Preset Arrays

    func test169PresetsCount() {
        XCTAssertEqual(VideoParameters.presets169.count, 9)
    }

    func test43PresetsCount() {
        XCTAssertEqual(VideoParameters.presets43.count, 9)
    }

    func testScreenSharePresetsCount() {
        XCTAssertEqual(VideoParameters.presetsScreenShare.count, 5)
    }

    func testDefaultSimulcastPresets169() {
        let presets = VideoParameters.defaultSimulcastPresets169
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets[0].dimensions, Dimensions.h180_169)
        XCTAssertEqual(presets[1].dimensions, Dimensions.h360_169)
    }

    func testDefaultSimulcastPresets43() {
        let presets = VideoParameters.defaultSimulcastPresets43
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets[0].dimensions, Dimensions.h180_43)
        XCTAssertEqual(presets[1].dimensions, Dimensions.h360_43)
    }

    // MARK: - Simulcast Layer Selection

    func testDefaultSimulcastLayers169() {
        let dims = Dimensions(width: 1280, height: 720)
        let params = VideoParameters(dimensions: dims, encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30))
        let layers = params.defaultSimulcastLayers(isScreenShare: false)
        XCTAssertEqual(layers.count, 2) // default simulcast = 2 layers
    }

    func testDefaultSimulcastLayers43() {
        let dims = Dimensions(width: 640, height: 480)
        let params = VideoParameters(dimensions: dims, encoding: VideoEncoding(maxBitrate: 500_000, maxFps: 20))
        let layers = params.defaultSimulcastLayers(isScreenShare: false)
        XCTAssertEqual(layers.count, 2)
    }

    func testDefaultScreenShareSimulcastLayers() {
        let dims = Dimensions(width: 1920, height: 1080)
        let params = VideoParameters(dimensions: dims, encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30))
        let layers = params.defaultSimulcastLayers(isScreenShare: true)
        XCTAssertEqual(layers.count, 1) // screenShare default = 1 extra layer
    }

    // MARK: - VideoEncoding Equality

    func testVideoEncodingEquality() {
        let a = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30)
        let b = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30)
        XCTAssertEqual(a, b)
    }

    func testVideoEncodingInequality() {
        let a = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30)
        let b = VideoEncoding(maxBitrate: 2_000_000, maxFps: 30)
        XCTAssertNotEqual(a, b)
    }

    func testVideoEncodingWithPriorities() {
        let a = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30, bitratePriority: .high, networkPriority: .low)
        let b = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30, bitratePriority: .high, networkPriority: .low)
        XCTAssertEqual(a, b)

        let c = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30, bitratePriority: .low, networkPriority: .low)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - VideoParameters Equality

    func testVideoParametersEquality() {
        let a = VideoParameters(dimensions: .h720_169, encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30))
        let b = VideoParameters(dimensions: .h720_169, encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30))
        XCTAssertEqual(a, b)
    }

    func testVideoParametersInequality() {
        let a = VideoParameters(dimensions: .h720_169, encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30))
        let b = VideoParameters(dimensions: .h1080_169, encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - VideoQuality RIDs

    func testVideoQualityRIDs() {
        XCTAssertEqual(VideoQuality.RIDs, ["q", "h", "f"])
    }

    func testVideoQualityFromRID() {
        XCTAssertEqual(Livekit_VideoQuality.from(rid: "q"), .low)
        XCTAssertEqual(Livekit_VideoQuality.from(rid: "h"), .medium)
        XCTAssertEqual(Livekit_VideoQuality.from(rid: "f"), .high)
        XCTAssertNil(Livekit_VideoQuality.from(rid: "x"))
        XCTAssertNil(Livekit_VideoQuality.from(rid: nil))
    }

    // MARK: - suggestedPresetIndex

    func testSuggestedPresetIndexByDimensions() {
        let presets = VideoParameters.presets169
        // 720p should match 6 presets (h90 through h720)
        let index = presets.suggestedPresetIndex(dimensions: .h720_169)
        XCTAssertEqual(index, 6) // h90, h180, h216, h360, h540, h720
    }

    func testSuggestedPresetIndexSmallDimensions() {
        let presets = VideoParameters.presets169
        // Tiny dimensions should have index 0
        let index = presets.suggestedPresetIndex(dimensions: Dimensions(width: 10, height: 6))
        XCTAssertEqual(index, 0)
    }
}
