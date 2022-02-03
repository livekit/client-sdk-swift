import Foundation
import CoreMedia
import WebRTC

// use CMVideoDimensions instead of defining our own struct
public typealias Dimensions = CMVideoDimensions

extension Dimensions {
    public static let aspectRatio169 = 16.0 / 9.0
    public static let aspectRatio43 = 4.0 / 3.0
    public static let zero = Dimensions(width: 0, height: 0)
}

extension Dimensions: Equatable {

    public static func == (lhs: Dimensions, rhs: Dimensions) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }
}

extension Dimensions {

    var aspectRatio: Double {
        let w = Double(width)
        let h = Double(height)
        return w > h ? w / h : h / w
    }

    var max: Int32 {
        Swift.max(width, height)
    }

    func computeSuggestedPresets(isScreenShare: Bool = false) -> [VideoParameters] {
        if isScreenShare {
            return VideoParameters.presetsScreenShare
        }
        if abs(aspectRatio - Dimensions.aspectRatio169) < abs(aspectRatio - Dimensions.aspectRatio43) {
            return VideoParameters.presets169
        }
        return VideoParameters.presets43
    }

    func computeSuggestedPreset(in presets: [VideoParameters]) -> VideoEncoding {
        assert(!presets.isEmpty)
        var result = presets[0].encoding
        for preset in presets {
            result = preset.encoding
            if preset.dimensions.width >= max {
                break
            }
        }
        return result
    }

    func encodings(from presets: [VideoParameters?]) -> [RTCRtpEncodingParameters] {
        var result: [RTCRtpEncodingParameters] = []
        for (index, preset) in presets.compactMap({ $0 }).enumerated() {
            guard let rid = videoRids[safe: index] else {
                continue
            }

            let parameters = Engine.createRtpEncodingParameters(
                rid: rid,
                encoding: preset.encoding,
                scaleDown: Double(max) / Double(preset.dimensions.max))

            result.append(parameters)
        }
        return result
    }

    func computeSuggestedPresetIndex(in presets: [VideoParameters]) -> Int {
        assert(!presets.isEmpty)
        var result = 0
        for preset in presets {
            if width >= preset.dimensions.width, height >= preset.dimensions.height {
                result += 1
            }
        }
        return result
    }
}

extension VideoEncoding {

}
