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

    static let presets43 = [
        presetQVGA43,
        presetVGA43,
        presetQHD43,
        presetHD43,
        presetFHD43
    ]

    static let presets169 = [
        presetQVGA169,
        presetVGA169,
        presetQHD169,
        presetHD169,
        presetFHD169
    ]

    static let presetsScreenShare = [
        presetScreenShareVGA,
        presetScreenShareHD5,
        presetScreenShareHD15,
        presetScreenShareFHD15,
        presetScreenShareFHD30
    ]
}
