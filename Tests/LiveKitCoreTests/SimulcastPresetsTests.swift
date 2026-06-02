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
import Testing

@Suite(.tags(.media))
struct SimulcastPresetsTests {
    @Test("Mid simulcast layer does not exceed user-configured top layer",
          .bug("https://github.com/livekit/client-sdk-swift/issues/1000"))
    func midLayerClampedToTop() throws {
        let dimensions = Dimensions(width: 1280, height: 720)
        let base = VideoParameters(
            dimensions: dimensions,
            encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 24),
        )

        let result = Utils.computeSimulcastPresets(
            dimensions: dimensions,
            baseParameters: base,
            requestedPresets: [.presetH720_169, .presetH360_169],
            isScreenShare: false,
        )

        try #require(result.count == 3)
        // Low (presetH360_169): smaller resolution, fps/bitrate already ≤ top — untouched.
        #expect(result[0].dimensions == .h360_169)
        #expect(result[0].encoding.maxFps == 20)
        #expect(result[0].encoding.maxBitrate == 450_000)
        // Mid (presetH720_169): same resolution as base, both fps and bitrate clamped down.
        #expect(result[1].dimensions == .h720_169)
        #expect(result[1].encoding.maxFps == 24)
        #expect(result[1].encoding.maxBitrate == 1_500_000)
        #expect(result[2] == base)
    }

    @Test("Layer ladder length follows the larger output dimension",
          arguments: [
              (Dimensions(width: 320, height: 240), 1),
              (Dimensions(width: 640, height: 480), 2),
              (Dimensions(width: 1280, height: 720), 3),
          ])
    func ladderLength(dimensions: Dimensions, expectedCount: Int) {
        let base = VideoParameters(
            dimensions: dimensions,
            encoding: VideoEncoding(maxBitrate: 1_000_000, maxFps: 30),
        )

        let result = Utils.computeSimulcastPresets(
            dimensions: dimensions,
            baseParameters: base,
            requestedPresets: [],
            isScreenShare: false,
        )

        #expect(result.count == expectedCount)
    }

    @Test("Lower-resolution layer clamps fps but preserves preset bitrate")
    func lowerResolutionFpsOnlyClamp() throws {
        let dimensions = Dimensions(width: 1280, height: 720)
        let base = VideoParameters(
            dimensions: dimensions,
            encoding: VideoEncoding(maxBitrate: 500_000, maxFps: 15),
        )

        let result = Utils.computeSimulcastPresets(
            dimensions: dimensions,
            baseParameters: base,
            requestedPresets: [],
            isScreenShare: false,
        )

        try #require(result.count == 3)
        // Default 16:9 ladder is [presetH180_169 (15fps, 160kbps), presetH360_169 (20fps, 450kbps)].
        // presetH360_169 has scaleDownBy=2 so its 450kbps survives; only fps is clamped to 15.
        #expect(result[1].dimensions == .h360_169)
        #expect(result[1].encoding.maxFps == 15)
        #expect(result[1].encoding.maxBitrate == 450_000)
    }

    @Test("Same-resolution lower layer clamps both fps and bitrate")
    func sameResolutionFullClamp() throws {
        let dimensions = Dimensions(width: 854, height: 480)
        let base = VideoParameters(
            dimensions: dimensions,
            encoding: VideoEncoding(maxBitrate: 600_000, maxFps: 15),
        )
        let aggressive = VideoParameters(
            dimensions: dimensions,
            encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 30),
        )

        let result = Utils.computeSimulcastPresets(
            dimensions: dimensions,
            baseParameters: base,
            requestedPresets: [aggressive],
            isScreenShare: false,
        )

        try #require(result.count == 2)
        #expect(result[0].encoding.maxFps == 15)
        #expect(result[0].encoding.maxBitrate == 600_000)
        #expect(result[1] == base)
    }

    @Test("Presets that don't overshoot are passed through unchanged")
    func happyPathUnchanged() throws {
        let dimensions = Dimensions(width: 1920, height: 1080)
        let base = VideoParameters(
            dimensions: dimensions,
            encoding: VideoEncoding(maxBitrate: 5_000_000, maxFps: 30),
        )

        let result = Utils.computeSimulcastPresets(
            dimensions: dimensions,
            baseParameters: base,
            requestedPresets: [.presetH360_169, .presetH720_169],
            isScreenShare: false,
        )

        try #require(result.count == 3)
        #expect(result[0] == VideoParameters.presetH360_169)
        #expect(result[1] == VideoParameters.presetH720_169)
        #expect(result[2] == base)
    }

    @Test("Clamped layer carries forward per-layer priorities")
    func priorities() throws {
        let dimensions = Dimensions(width: 1280, height: 720)
        let base = VideoParameters(
            dimensions: dimensions,
            encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 24),
        )
        let prioritized = VideoParameters(
            dimensions: dimensions,
            encoding: VideoEncoding(
                maxBitrate: 1_700_000,
                maxFps: 30,
                bitratePriority: .high,
                networkPriority: .high,
            ),
        )

        let result = Utils.computeSimulcastPresets(
            dimensions: dimensions,
            baseParameters: base,
            requestedPresets: [.presetH360_169, prioritized],
            isScreenShare: false,
        )

        try #require(result.count == 3)
        #expect(result[1].encoding.maxFps == 24)
        #expect(result[1].encoding.maxBitrate == 1_500_000)
        #expect(result[1].encoding.bitratePriority == .high)
        #expect(result[1].encoding.networkPriority == .high)
    }
}
