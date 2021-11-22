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

    // 4:3 aspect ratio
    public static let presetQVGA43 = VideoParameters(
        dimensions: Dimensions(width: 240, height: 180),
        encoding: VideoEncoding(maxBitrate: 100_000, maxFps: 15)
    )
    public static let presetVGA43 = VideoParameters(
        dimensions: Dimensions(width: 480, height: 360),
        encoding: VideoEncoding(maxBitrate: 320_000, maxFps: 30)
    )
    public static let presetQHD43 = VideoParameters(
        dimensions: Dimensions(width: 720, height: 540),
        encoding: VideoEncoding(maxBitrate: 640_000, maxFps: 30)
    )
    public static let presetHD43 = VideoParameters(
        dimensions: Dimensions(width: 960, height: 720),
        encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 30)
    )
    public static let presetFHD43 = VideoParameters(
        dimensions: Dimensions(width: 1440, height: 1080),
        encoding: VideoEncoding(maxBitrate: 3_200_000, maxFps: 30)
    )

    // 16:9 aspect ratio
    public static let presetQVGA169 = VideoParameters(
        dimensions: Dimensions(width: 320, height: 180),
        encoding: VideoEncoding(maxBitrate: 125_000, maxFps: 15)
    )
    public static let presetVGA169 = VideoParameters(
        dimensions: Dimensions(width: 640, height: 360),
        encoding: VideoEncoding(maxBitrate: 400_000, maxFps: 30)
    )
    public static let presetQHD169 = VideoParameters(
        dimensions: Dimensions(width: 960, height: 540),
        encoding: VideoEncoding(maxBitrate: 800_000, maxFps: 30)
    )
    public static let presetHD169 = VideoParameters(
        dimensions: Dimensions(width: 1280, height: 720),
        encoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 30)
    )
    public static let presetFHD169 = VideoParameters(
        dimensions: Dimensions(width: 1920, height: 1080),
        encoding: VideoEncoding(maxBitrate: 4_000_000, maxFps: 30)
    )

    public static let presets43 = [
        presetQVGA43, presetVGA43, presetQHD43, presetHD43, presetFHD43
    ]

    public static let presets169 = [
        presetQVGA169, presetVGA169, presetQHD169, presetHD169, presetFHD169
    ]

    public let dimensions: Dimensions
    public let encoding: VideoEncoding

    init(dimensions: Dimensions, encoding: VideoEncoding) {
        self.dimensions = dimensions
        self.encoding = encoding
    }

    //    static func getPresetForDimension(width: Int, height: Int) -> VideoParameters {
    //        var preset = presets169[0]
    //        for p in presets169 {
    //            if width >= p.capture.width, height >= p.capture.height {
    //                preset = p
    //            }
    //        }
    //        return preset
    //    }

    //    /// creates encoding parameters that best match input width/height
    //    static func getRTPEncodingParams(inputWidth: Int, inputHeight: Int, rid: String?, encoding: VideoEncoding? = nil) -> RTCRtpEncodingParameters? {
    //        var scaleDownFactor = 1.0
    //        if rid == "h" {
    //            scaleDownFactor = 2.0
    //        } else if rid == "q" {
    //            scaleDownFactor = 4.0
    //        }
    //        var targetWidth = Int(Double(inputWidth) / scaleDownFactor)
    //        var targetHeight = Int(Double(inputHeight) / scaleDownFactor)
    //
    //        var selectedEncoding: VideoEncoding
    //
    //        if targetWidth < simulcastMinWidth {
    //            return nil
    //        }
    //
    //        // unless it's original, find the best resolution
    //        if scaleDownFactor != 1.0 || encoding == nil {
    //            let preset = getPresetForDimension(width: targetWidth, height: targetHeight)
    //            targetWidth = preset.capture.width
    //            scaleDownFactor = Double(inputWidth) / Double(targetWidth)
    //            targetHeight = Int(Double(inputHeight) / scaleDownFactor)
    //
    //            selectedEncoding = preset.encoding
    //        } else {
    //            selectedEncoding = encoding!
    //        }
    //
    //        let params = RTCRtpEncodingParameters()
    //        params.isActive = true
    //        params.rid = rid
    //        params.scaleResolutionDownBy = NSNumber(value: scaleDownFactor)
    //        params.maxFramerate = NSNumber(value: selectedEncoding.maxFps)
    //        params.maxBitrateBps = NSNumber(value: selectedEncoding.maxBitrate)
    //        // only set on the full track
    //        if scaleDownFactor == 1.0 {
    //            params.networkPriority = .high
    //            params.bitratePriority = 4.0
    //        } else {
    //            params.networkPriority = .low
    //            params.bitratePriority = 1.0
    //        }
    //        return params
    //    }
}
