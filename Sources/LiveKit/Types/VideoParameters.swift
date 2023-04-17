/*
 * Copyright 2022 LiveKit
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
import WebRTC

extension Collection where Element == VideoParameters {

    func suggestedPresetIndex(dimensions: Dimensions? = nil,
                              videoEncoding: VideoEncoding? = nil) -> Int {
        // self must at lease have 1 element
        assert(!isEmpty)
        // dimensions or videoEndocing is required
        assert(dimensions != nil || videoEncoding != nil)

        var result = 0
        for preset in self {
            if let dimensions = dimensions,
               dimensions.width >= preset.dimensions.width,
               dimensions.height >= preset.dimensions.height {

                result += 1
            } else if let videoEncoding = videoEncoding,
                      videoEncoding.maxBitrate >= preset.encoding.maxBitrate {
                result += 1
            }

        }
        return result
    }
}

@objc
public class VideoParameters: NSObject {

    @objc
    public let dimensions: Dimensions

    @objc
    public let encoding: VideoEncoding

    @objc
    public init(dimensions: Dimensions, encoding: VideoEncoding) {
        self.dimensions = dimensions
        self.encoding = encoding
    }

    // MARK: - Equal

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return self.dimensions == other.dimensions &&
            self.encoding == other.encoding
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(dimensions)
        hasher.combine(encoding)
        return hasher.finalize()
    }
}

// MARK: - Computation

internal extension VideoParameters {

    func defaultScreenShareSimulcastLayers() -> [VideoParameters] {

        struct Layer {
            let scaleDownBy: Double
            let fps: Int
        }

        let layers = [Layer(scaleDownBy: 2, fps: 3)]

        return layers.map {
            let dimensions = Dimensions(width: Int32((Double(dimensions.width) / $0.scaleDownBy).rounded(.down)),
                                        height: Int32((Double(dimensions.height) / $0.scaleDownBy).rounded(.down)))
            let bitrate2 = Int((Double(encoding.maxBitrate) / (pow(Double($0.scaleDownBy), 2) * (Double(encoding.maxFps) / Double($0.fps)))).rounded(.down))
            let encoding = VideoEncoding(maxBitrate: Swift.max(150_000, bitrate2), maxFps: $0.fps)

            return VideoParameters(dimensions: dimensions, encoding: encoding)
        }
    }

    func defaultSimulcastLayers(isScreenShare: Bool) -> [VideoParameters] {
        if isScreenShare {
            return defaultScreenShareSimulcastLayers()
        }
        if abs(dimensions.aspectRatio - Dimensions.aspectRatio169) < abs(dimensions.aspectRatio - Dimensions.aspectRatio43) {
            return VideoParameters.defaultSimulcastPresets169
        }
        return VideoParameters.defaultSimulcastPresets43
    }
}

// MARK: - Presets

@objc
extension VideoParameters {

    internal static let presets43 = [
        presetH120_43,
        presetH180_43,
        presetH240_43,
        presetH360_43,
        presetH480_43,
        presetH540_43,
        presetH720_43,
        presetH1080_43,
        presetH1440_43
    ]

    internal static let presets169 = [
        presetH90_169,
        presetH180_169,
        presetH216_169,
        presetH360_169,
        presetH540_169,
        presetH720_169,
        presetH1080_169,
        presetH1440_169,
        presetH2160_169
    ]

    internal static let presetsScreenShare = [
        presetScreenShareH360FPS3,
        presetScreenShareH720FPS5,
        presetScreenShareH720FPS15,
        presetScreenShareH1080FPS15,
        presetScreenShareH1080FPS30
    ]

    internal static let defaultSimulcastPresets169 = [
        presetH180_169,
        presetH360_169
    ]

    internal static let defaultSimulcastPresets43 = [
        presetH180_43,
        presetH360_43
    ]

    // 16:9 aspect ratio
    public static let presetH90_169 = VideoParameters(
        dimensions: .h90_169,
        encoding: VideoEncoding(maxBitrate: 60_000, maxFps: 15)
    )

    public static let presetH180_169 = VideoParameters(
        dimensions: .h180_169,
        encoding: VideoEncoding(maxBitrate: 120_000, maxFps: 15)
    )

    public static let presetH216_169 = VideoParameters(
        dimensions: .h216_169,
        encoding: VideoEncoding(maxBitrate: 180_000, maxFps: 15)
    )

    public static let presetH360_169 = VideoParameters(
        dimensions: .h360_169,
        encoding: VideoEncoding(maxBitrate: 300_000, maxFps: 20)
    )

    public static let presetH540_169 = VideoParameters(
        dimensions: .h540_169,
        encoding: VideoEncoding(maxBitrate: 600_000, maxFps: 25)
    )

    public static let presetH720_169 = VideoParameters(
        dimensions: .h720_169,
        encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30)
    )

    public static let presetH1080_169 = VideoParameters(
        dimensions: .h1080_169,
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )

    public static let presetH1440_169 = VideoParameters(
        dimensions: .h1440_169,
        encoding: VideoEncoding(maxBitrate: 5_000_000, maxFps: 30)
    )

    public static let presetH2160_169 = VideoParameters(
        dimensions: .h2160_169,
        encoding: VideoEncoding(maxBitrate: 8_000_000, maxFps: 30)
    )

    // 4:3 aspect ratio
    public static let presetH120_43 = VideoParameters(
        dimensions: .h120_43,
        encoding: VideoEncoding(maxBitrate: 80_000, maxFps: 15)
    )

    public static let presetH180_43 = VideoParameters(
        dimensions: .h180_43,
        encoding: VideoEncoding(maxBitrate: 100_000, maxFps: 15)
    )

    public static let presetH240_43 = VideoParameters(
        dimensions: .h240_43,
        encoding: VideoEncoding(maxBitrate: 150_000, maxFps: 15)
    )

    public static let presetH360_43 = VideoParameters(
        dimensions: .h360_43,
        encoding: VideoEncoding(maxBitrate: 225_000, maxFps: 20)
    )

    public static let presetH480_43 = VideoParameters(
        dimensions: .h480_43,
        encoding: VideoEncoding(maxBitrate: 300_000, maxFps: 20)
    )

    public static let presetH540_43 = VideoParameters(
        dimensions: .h540_43,
        encoding: VideoEncoding(maxBitrate: 450_000, maxFps: 25)
    )

    public static let presetH720_43 = VideoParameters(
        dimensions: .h720_43,
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 30)
    )

    public static let presetH1080_43 = VideoParameters(
        dimensions: .h1080_43,
        encoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 30)
    )

    public static let presetH1440_43 = VideoParameters(
        dimensions: .h1440_43,
        encoding: VideoEncoding(maxBitrate: 3_500_000, maxFps: 30)
    )

    // Screen share
    public static let presetScreenShareH360FPS3 = VideoParameters(
        dimensions: .h360_169,
        encoding: VideoEncoding(maxBitrate: 200_000, maxFps: 3)
    )

    public static let presetScreenShareH720FPS5 = VideoParameters(
        dimensions: .h720_169,
        encoding: VideoEncoding(maxBitrate: 400_000, maxFps: 5)
    )

    public static let presetScreenShareH720FPS15 = VideoParameters(
        dimensions: .h720_169,
        encoding: VideoEncoding(maxBitrate: 1_000_000, maxFps: 15)
    )

    public static let presetScreenShareH1080FPS15 = VideoParameters(
        dimensions: .h1080_169,
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 15)
    )

    public static let presetScreenShareH1080FPS30 = VideoParameters(
        dimensions: .h1080_169,
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )
}
