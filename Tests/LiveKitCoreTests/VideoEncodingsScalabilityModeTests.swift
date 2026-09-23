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
import Testing

struct VideoEncodingsScalabilityModeTests {
    private let dimensions = Dimensions(width: 1280, height: 720)

    @Test func svcDefaultsToL3T3KeyForCamera() {
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: VideoPublishOptions(preferredCodec: .vp9))
        #expect(encodings.count == 1)
        #expect(encodings[0].scalabilityMode == "L3T3_KEY")
    }

    @Test func svcDefaultsToL1T3ForScreenShare() {
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: VideoPublishOptions(preferredCodec: .vp9),
                                                    isScreenShare: true)
        #expect(encodings.count == 1)
        #expect(encodings[0].scalabilityMode == "L1T3")
    }

    @Test func explicitScalabilityModeWinsForSvcCamera() {
        let options = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L1T3)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions, publishOptions: options)
        #expect(encodings.count == 1)
        #expect(encodings[0].scalabilityMode == "L1T3")
    }

    /// Backup-codec and republish paths pass `overrideVideoCodec`; the option must still apply,
    /// otherwise the mode silently reverts exactly where the freeze shows up.
    @Test func explicitScalabilityModeSurvivesCodecOverride() {
        let options = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L1T3)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: options,
                                                    overrideVideoCodec: .av1)
        #expect(encodings.count == 1)
        #expect(encodings[0].scalabilityMode == "L1T3")
    }

    /// WebRTC does not publish SVC screen share with multiple spatial layers, so `.L1T3` is forced
    /// there regardless of the option — otherwise the encoder emits no frames and subscribers get a
    /// blank screen share.
    @Test func explicitScalabilityModeIsIgnoredForScreenShare() {
        let options = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L3T3_KEY)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: options,
                                                    isScreenShare: true)
        #expect(encodings.count == 1)
        #expect(encodings[0].scalabilityMode == "L1T3")
    }

    @Test func scalabilityModeIsIgnoredForNonSvcCodec() {
        let options = VideoPublishOptions(preferredCodec: .vp8, scalabilityMode: .L1T3)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions, publishOptions: options)
        #expect(encodings.count > 1)
        #expect(encodings.allSatisfy { $0.scalabilityMode == nil })
    }

    /// The initializer that existed before `scalabilityMode` is kept for Objective-C consumers
    /// compiled against the previous framework; it must behave as `scalabilityMode: nil`.
    @Test func legacyInitializerDefaultsScalabilityModeToNil() {
        let legacy = VideoPublishOptions(preferredCodec: .vp9, degradationPreference: .auto)
        #expect(legacy.scalabilityMode == nil)
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions, publishOptions: legacy)
        #expect(encodings[0].scalabilityMode == "L3T3_KEY")
    }

    @Test func optionsEqualityIncludesScalabilityMode() {
        let l1t3 = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L1T3)
        let l3t3Key = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L3T3_KEY)
        let sameAsL1T3 = VideoPublishOptions(preferredCodec: .vp9, scalabilityMode: .L1T3)
        #expect(l1t3 != l3t3Key)
        #expect(l1t3 == sameAsL1T3)
        #expect(l1t3.hash == sameAsL1T3.hash)
    }
}
