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

    static let presets43 = [
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

    static let presets169 = [
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

    static let presetsScreenShare = [
        presetScreenShareH360FPS3,
        presetScreenShareH720FPS5,
        presetScreenShareH720FPS15,
        presetScreenShareH1080FPS15,
        presetScreenShareH1080FPS30
    ]

    static let defaultSimulcastPresets169 = [
        presetH180_169,
        presetH360_169
    ]

    static let defaultSimulcastPresets43 = [
        presetH180_43,
        presetH360_43
    ]

    // 16:9 aspect ratio

    static let presetH90_169 = VideoParameters(
        dimensions: .h90_169,
        encoding: VideoEncoding(maxBitrate: 60_000, maxFps: 15)
    )

    static let presetH180_169 = VideoParameters(
        dimensions: .h180_169,
        encoding: VideoEncoding(maxBitrate: 120_000, maxFps: 15)
    )

    static let presetH216_169 = VideoParameters(
        dimensions: .h216_169,
        encoding: VideoEncoding(maxBitrate: 180_000, maxFps: 15)
    )

    static let presetH360_169 = VideoParameters(
        dimensions: .h360_169,
        encoding: VideoEncoding(maxBitrate: 300_000, maxFps: 20)
    )

    static let presetH540_169 = VideoParameters(
        dimensions: .h540_169,
        encoding: VideoEncoding(maxBitrate: 600_000, maxFps: 25)
    )

    static let presetH720_169 = VideoParameters(
        dimensions: .h720_169,
        encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 30)
    )

    static let presetH1080_169 = VideoParameters(
        dimensions: .h1080_169,
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )

    static let presetH1440_169 = VideoParameters(
        dimensions: .h1440_169,
        encoding: VideoEncoding(maxBitrate: 5_000_000, maxFps: 30)
    )

    static let presetH2160_169 = VideoParameters(
        dimensions: .h2160_169,
        encoding: VideoEncoding(maxBitrate: 8_000_000, maxFps: 30)
    )

    // 4:3 aspect ratio

    static let presetH120_43 = VideoParameters(
        dimensions: .h120_43,
        encoding: VideoEncoding(maxBitrate: 80_000, maxFps: 15)
    )

    static let presetH180_43 = VideoParameters(
        dimensions: .h180_43,
        encoding: VideoEncoding(maxBitrate: 100_000, maxFps: 15)
    )

    static let presetH240_43 = VideoParameters(
        dimensions: .h240_43,
        encoding: VideoEncoding(maxBitrate: 150_000, maxFps: 15)
    )

    static let presetH360_43 = VideoParameters(
        dimensions: .h360_43,
        encoding: VideoEncoding(maxBitrate: 225_000, maxFps: 20)
    )

    static let presetH480_43 = VideoParameters(
        dimensions: .h480_43,
        encoding: VideoEncoding(maxBitrate: 300_000, maxFps: 20)
    )

    static let presetH540_43 = VideoParameters(
        dimensions: .h540_43,
        encoding: VideoEncoding(maxBitrate: 450_000, maxFps: 25)
    )

    static let presetH720_43 = VideoParameters(
        dimensions: .h720_43,
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 30)
    )

    static let presetH1080_43 = VideoParameters(
        dimensions: .h1080_43,
        encoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 30)
    )

    static let presetH1440_43 = VideoParameters(
        dimensions: .h1440_43,
        encoding: VideoEncoding(maxBitrate: 3_500_000, maxFps: 30)
    )

    // Screen share

    static let presetScreenShareH360FPS3 = VideoParameters(
        dimensions: .h360_169,
        encoding: VideoEncoding(maxBitrate: 200_000, maxFps: 3)
    )

    static let presetScreenShareH720FPS5 = VideoParameters(
        dimensions: .h720_169,
        encoding: VideoEncoding(maxBitrate: 400_000, maxFps: 5)
    )

    static let presetScreenShareH720FPS15 = VideoParameters(
        dimensions: .h720_169,
        encoding: VideoEncoding(maxBitrate: 1_000_000, maxFps: 15)
    )

    static let presetScreenShareH1080FPS15 = VideoParameters(
        dimensions: .h1080_169,
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 15)
    )

    static let presetScreenShareH1080FPS30 = VideoParameters(
        dimensions: .h1080_169,
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )
}

extension VideoParameters: Comparable {

    public static func < (lhs: VideoParameters, rhs: VideoParameters) -> Bool {

        if lhs.dimensions.area == rhs.dimensions.area {
            return lhs.encoding < rhs.encoding
        }

        return lhs.dimensions.area < rhs.dimensions.area
    }

    public static func == (lhs: VideoParameters, rhs: VideoParameters) -> Bool {
        lhs.dimensions == rhs.dimensions &&
            lhs.encoding == rhs.encoding
    }
}

// MARK: - Presets(Deprecated)

@available(*, deprecated)
public extension VideoParameters {

    // 4:3 aspect ratio
    static let presetQVGA43 = VideoParameters(
        dimensions: .qvga43,
        encoding: VideoEncoding(maxBitrate: 90_000, maxFps: 10)
    )

    static let presetVGA43 = VideoParameters(
        dimensions: .vga43,
        encoding: VideoEncoding(maxBitrate: 225_000, maxFps: 20)
    )

    static let presetQHD43 = VideoParameters(
        dimensions: .qhd43,
        encoding: VideoEncoding(maxBitrate: 450_000, maxFps: 25)
    )

    static let presetHD43 = VideoParameters(
        dimensions: .hd43,
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 30)
    )

    static let presetFHD43 = VideoParameters(
        dimensions: .fhd43,
        encoding: VideoEncoding(maxBitrate: 2_800_000, maxFps: 30)
    )

    // 16:9 aspect ratio
    static let presetQVGA169 = VideoParameters(
        dimensions: .qvga169,
        encoding: VideoEncoding(maxBitrate: 120_000, maxFps: 10)
    )

    static let presetVGA169 = VideoParameters(
        dimensions: .vga169,
        encoding: VideoEncoding(maxBitrate: 300_000, maxFps: 20)
    )

    static let presetQHD169 = VideoParameters(
        dimensions: .qhd169,
        encoding: VideoEncoding(maxBitrate: 600_000, maxFps: 25)
    )

    static let presetHD169 = VideoParameters(
        dimensions: .hd169,
        encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 30)
    )

    static let presetFHD169 = VideoParameters(
        dimensions: .fhd169,
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )

    // Screen share
    static let presetScreenShareVGA = VideoParameters(
        dimensions: .vga169,
        encoding: VideoEncoding(maxBitrate: 200_000, maxFps: 3)
    )

    static let presetScreenShareHD5 = VideoParameters(
        dimensions: .hd169,
        encoding: VideoEncoding(maxBitrate: 400_000, maxFps: 5)
    )

    static let presetScreenShareHD15 = VideoParameters(
        dimensions: .hd169,
        encoding: VideoEncoding(maxBitrate: 1_000_000, maxFps: 15)
    )

    static let presetScreenShareFHD15 = VideoParameters(
        dimensions: .fhd169,
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 15)
    )

    static let presetScreenShareFHD30 = VideoParameters(
        dimensions: .fhd169,
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )
}
