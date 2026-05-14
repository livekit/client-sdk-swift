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

internal import LiveKitWebRTC

extension Utils {
    static func computeVideoEncodings(
        dimensions: Dimensions,
        publishOptions: VideoPublishOptions?,
        isScreenShare: Bool = false,
        overrideVideoCodec: VideoCodec? = nil
    ) -> [LKRTCRtpEncodingParameters] {
        let publishOptions = publishOptions ?? VideoPublishOptions()
        let preferredEncoding: VideoEncoding? = isScreenShare ? publishOptions.screenShareEncoding : publishOptions.encoding
        let encoding = preferredEncoding ?? dimensions.computeSuggestedPreset(in: dimensions.computeSuggestedPresets(isScreenShare: isScreenShare))

        let videoCodec = overrideVideoCodec ?? publishOptions.preferredCodec

        if let videoCodec, videoCodec.isSVC {
            // SVC mode
            log("Using SVC mode")
            // VP9/AV1 with screen sharing requires single spatial layer
            return [RTC.createRtpEncodingParameters(encoding: encoding, scalabilityMode: isScreenShare ? .L1T3 : .L3T3_KEY)]
        } else if !publishOptions.simulcast {
            // Not-simulcast mode
            log("Simulcast not enabled")
            return [RTC.createRtpEncodingParameters(encoding: encoding)]
        }

        // Continue to simulcast encoding computation...

        let baseParameters = VideoParameters(dimensions: dimensions,
                                             encoding: encoding)

        let requestedPresets = isScreenShare ? publishOptions.screenShareSimulcastLayers : publishOptions.simulcastLayers
        let resultPresets = computeSimulcastPresets(dimensions: dimensions,
                                                    baseParameters: baseParameters,
                                                    requestedPresets: requestedPresets,
                                                    isScreenShare: isScreenShare)

        log("Using presets: \(resultPresets), count: \(resultPresets.count) isScreenShare: \(isScreenShare)")

        return dimensions.encodings(from: resultPresets)
    }

    /// Builds the ordered simulcast layer list (low → high). The top layer is always
    /// `baseParameters`; lower layers are clamped so that no layer exceeds the top layer's
    /// `maxFps`, and same-resolution lower layers are additionally clamped against the top's
    /// `maxBitrate` (a layer that does not scale resolution down must not be allowed to spend
    /// more bandwidth than the top). Layer count depends on the larger output dimension:
    /// `< 480` → 1 layer, `[480, 960)` → 2 layers, `≥ 960` → 3 layers.
    static func computeSimulcastPresets(
        dimensions: Dimensions,
        baseParameters: VideoParameters,
        requestedPresets: [VideoParameters],
        isScreenShare: Bool
    ) -> [VideoParameters] {
        let presets = (!requestedPresets.isEmpty
            ? requestedPresets
            : baseParameters.defaultSimulcastLayers(isScreenShare: isScreenShare))
            .sorted { $0 < $1 }

        guard let lowPreset = presets.first else {
            return [baseParameters]
        }
        let midPreset = presets[safe: 1]

        if dimensions.max >= 960, let midPreset {
            return [clamp(preset: lowPreset, to: baseParameters, in: dimensions),
                    clamp(preset: midPreset, to: baseParameters, in: dimensions),
                    baseParameters]
        }
        if dimensions.max >= 480 {
            return [clamp(preset: lowPreset, to: baseParameters, in: dimensions),
                    baseParameters]
        }
        return [baseParameters]
    }

    private static func clamp(preset: VideoParameters,
                              to base: VideoParameters,
                              in dimensions: Dimensions) -> VideoParameters
    {
        let presetEncoding = preset.encoding
        let baseEncoding = base.encoding
        let scaleDownBy = Double(dimensions.max) / Double(preset.dimensions.max)

        let clampedFps = Swift.min(presetEncoding.maxFps, baseEncoding.maxFps)
        // Only clamp bitrate when the preset would not actually scale resolution down — a
        // same-resolution lower layer must not be allowed to spend more bandwidth than the top.
        let clampedBitrate = scaleDownBy <= 1.0
            ? Swift.min(presetEncoding.maxBitrate, baseEncoding.maxBitrate)
            : presetEncoding.maxBitrate

        if clampedFps == presetEncoding.maxFps, clampedBitrate == presetEncoding.maxBitrate {
            return preset
        }
        return VideoParameters(
            dimensions: preset.dimensions,
            encoding: VideoEncoding(
                maxBitrate: clampedBitrate,
                maxFps: clampedFps,
                bitratePriority: presetEncoding.bitratePriority,
                networkPriority: presetEncoding.networkPriority
            )
        )
    }
}
