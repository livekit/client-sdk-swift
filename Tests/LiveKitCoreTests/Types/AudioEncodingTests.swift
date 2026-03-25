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

/// Tests for AudioEncoding, VideoEncoding+Comparable, and VideoParameters+Comparable.
class AudioEncodingTests: LKTestCase {
    // MARK: - AudioEncoding init

    func testAudioEncodingSimpleInit() {
        let enc = AudioEncoding(maxBitrate: 48000)
        XCTAssertEqual(enc.maxBitrate, 48000)
        XCTAssertNil(enc.bitratePriority)
        XCTAssertNil(enc.networkPriority)
    }

    func testAudioEncodingFullInit() {
        let enc = AudioEncoding(maxBitrate: 96000, bitratePriority: .high, networkPriority: .medium)
        XCTAssertEqual(enc.maxBitrate, 96000)
        XCTAssertEqual(enc.bitratePriority, .high)
        XCTAssertEqual(enc.networkPriority, .medium)
    }

    // MARK: - AudioEncoding equality

    func testAudioEncodingEquality() {
        let a = AudioEncoding(maxBitrate: 48000)
        let b = AudioEncoding(maxBitrate: 48000)
        XCTAssertEqual(a, b)
    }

    func testAudioEncodingInequality() {
        let a = AudioEncoding(maxBitrate: 48000)
        let b = AudioEncoding(maxBitrate: 64000)
        XCTAssertNotEqual(a, b)
    }

    func testAudioEncodingEqualityWithPriorities() {
        let a = AudioEncoding(maxBitrate: 96000, bitratePriority: .high, networkPriority: .low)
        let b = AudioEncoding(maxBitrate: 96000, bitratePriority: .high, networkPriority: .low)
        XCTAssertEqual(a, b)

        let c = AudioEncoding(maxBitrate: 96000, bitratePriority: .low, networkPriority: .low)
        XCTAssertNotEqual(a, c)
    }

    func testAudioEncodingIsNotEqualToNonAudioEncoding() {
        let enc = AudioEncoding(maxBitrate: 48000)
        XCTAssertFalse(enc.isEqual("not an encoding"))
        XCTAssertFalse(enc.isEqual(nil))
    }

    // MARK: - AudioEncoding hash

    func testAudioEncodingHash() {
        let a = AudioEncoding(maxBitrate: 48000)
        let b = AudioEncoding(maxBitrate: 48000)
        XCTAssertEqual(a.hash, b.hash)
    }

    // MARK: - AudioEncoding presets

    func testAudioEncodingPresets() {
        XCTAssertEqual(AudioEncoding.presets.count, 6)
        XCTAssertEqual(AudioEncoding.presetTelephone.maxBitrate, 12000)
        XCTAssertEqual(AudioEncoding.presetSpeech.maxBitrate, 24000)
        XCTAssertEqual(AudioEncoding.presetMusic.maxBitrate, 48000)
        XCTAssertEqual(AudioEncoding.presetMusicStereo.maxBitrate, 64000)
        XCTAssertEqual(AudioEncoding.presetMusicHighQuality.maxBitrate, 96000)
        XCTAssertEqual(AudioEncoding.presetMusicHighQualityStereo.maxBitrate, 128_000)
    }

    func testAudioEncodingPresetsAreOrderedByBitrate() {
        let bitrates = AudioEncoding.presets.map(\.maxBitrate)
        XCTAssertEqual(bitrates, bitrates.sorted())
    }

    // MARK: - VideoEncoding Comparable

    func testVideoEncodingLessThanByBitrate() {
        let low = VideoEncoding(maxBitrate: 500_000, maxFps: 30)
        let high = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30)
        XCTAssertTrue(low < high)
        XCTAssertFalse(high < low)
    }

    func testVideoEncodingLessThanByFpsWhenBitrateEqual() {
        let lowFps = VideoEncoding(maxBitrate: 1_000_000, maxFps: 15)
        let highFps = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30)
        XCTAssertTrue(lowFps < highFps)
    }

    func testVideoEncodingNotLessThanWhenEqual() {
        let a = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30)
        let b = VideoEncoding(maxBitrate: 1_000_000, maxFps: 30)
        XCTAssertFalse(a < b)
    }

    // MARK: - VideoParameters Comparable

    func testVideoParametersLessThanByArea() {
        let small = VideoParameters(dimensions: .h360_169, encoding: VideoEncoding(maxBitrate: 450_000, maxFps: 20))
        let large = VideoParameters(dimensions: .h720_169, encoding: VideoEncoding(maxBitrate: 450_000, maxFps: 20))
        XCTAssertTrue(small < large)
    }

    func testVideoParametersLessThanByEncodingWhenAreaEqual() {
        let lowBitrate = VideoParameters(dimensions: .h720_169, encoding: VideoEncoding(maxBitrate: 500_000, maxFps: 30))
        let highBitrate = VideoParameters(dimensions: .h720_169, encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30))
        XCTAssertTrue(lowBitrate < highBitrate)
    }

    // MARK: - VideoParameters suggestedPresetIndex (videoEncoding path)

    func testSuggestedPresetIndexByVideoEncoding() {
        let presets = VideoParameters.presets169
        let encoding = VideoEncoding(maxBitrate: 450_000, maxFps: 20) // matches 360p
        let index = presets.suggestedPresetIndex(videoEncoding: encoding)
        // Counts how many presets have maxBitrate <= 450000
        XCTAssertTrue(index > 0)
    }

    // MARK: - VideoParameters hash

    func testVideoParametersHash() {
        let a = VideoParameters(dimensions: .h720_169, encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30))
        let b = VideoParameters(dimensions: .h720_169, encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30))
        XCTAssertEqual(a.hash, b.hash)
    }
}
