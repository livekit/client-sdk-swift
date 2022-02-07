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

public struct VideoParameters {

    public let dimensions: Dimensions
    public let encoding: VideoEncoding

    public init(dimensions: Dimensions, encoding: VideoEncoding) {
        self.dimensions = dimensions
        self.encoding = encoding
    }
}

// MARK: - Presets

public extension VideoParameters {

    // 4:3 aspect ratio
    public static let presetQVGA43 = VideoParameters(
        dimensions: Dimensions(width: 240, height: 180),
        encoding: VideoEncoding(maxBitrate: 90_000, maxFps: 10)
    )

    public static let presetVGA43 = VideoParameters(
        dimensions: Dimensions(width: 480, height: 360),
        encoding: VideoEncoding(maxBitrate: 225_000, maxFps: 20)
    )

    public static let presetQHD43 = VideoParameters(
        dimensions: Dimensions(width: 720, height: 540),
        encoding: VideoEncoding(maxBitrate: 450_000, maxFps: 25)
    )

    public static let presetHD43 = VideoParameters(
        dimensions: Dimensions(width: 960, height: 720),
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 30)
    )

    public static let presetFHD43 = VideoParameters(
        dimensions: Dimensions(width: 1440, height: 1080),
        encoding: VideoEncoding(maxBitrate: 2_800_000, maxFps: 30)
    )

    // 16:9 aspect ratio
    public static let presetQVGA169 = VideoParameters(
        dimensions: Dimensions(width: 320, height: 180),
        encoding: VideoEncoding(maxBitrate: 120_000, maxFps: 10)
    )

    public static let presetVGA169 = VideoParameters(
        dimensions: Dimensions(width: 640, height: 360),
        encoding: VideoEncoding(maxBitrate: 300_000, maxFps: 20)
    )

    public static let presetQHD169 = VideoParameters(
        dimensions: Dimensions(width: 960, height: 540),
        encoding: VideoEncoding(maxBitrate: 600_000, maxFps: 25)
    )

    public static let presetHD169 = VideoParameters(
        dimensions: Dimensions(width: 1280, height: 720),
        encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 30)
    )

    public static let presetFHD169 = VideoParameters(
        dimensions: Dimensions(width: 1920, height: 1080),
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )

    // Screen share
    public static let presetScreenShareVGA = VideoParameters(
        dimensions: Dimensions(width: 640, height: 360),
        encoding: VideoEncoding(maxBitrate: 200_000, maxFps: 3)
    )

    public static let presetScreenShareHD5 = VideoParameters(
        dimensions: Dimensions(width: 1280, height: 720),
        encoding: VideoEncoding(maxBitrate: 400_000, maxFps: 5)
    )

    public static let presetScreenShareHD15 = VideoParameters(
        dimensions: Dimensions(width: 1280, height: 720),
        encoding: VideoEncoding(maxBitrate: 1_000_000, maxFps: 15)
    )

    public static let presetScreenShareFHD15 = VideoParameters(
        dimensions: Dimensions(width: 1920, height: 1080),
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 15)
    )

    public static let presetScreenShareFHD30 = VideoParameters(
        dimensions: Dimensions(width: 1920, height: 1080),
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )

    public static let presets43 = [
        presetQVGA43,
        presetVGA43,
        presetQHD43,
        presetHD43,
        presetFHD43
    ]

    public static let presets169 = [
        presetQVGA169,
        presetVGA169,
        presetQHD169,
        presetHD169,
        presetFHD169
    ]

    public static let presetsScreenShare = [
        presetScreenShareVGA,
        presetScreenShareHD5,
        presetScreenShareHD15,
        presetScreenShareFHD15,
        presetScreenShareFHD30
    ]
}
