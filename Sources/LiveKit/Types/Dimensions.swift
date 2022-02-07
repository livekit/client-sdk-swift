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

// this may cause ambiguity to comparison
// extension Dimensions: Comparable {
//
//    // compares by resolution
//    public static func < (lhs: CMVideoDimensions, rhs: CMVideoDimensions) -> Bool {
//        lhs.area < rhs.area
//    }
// }

extension Dimensions {

    var aspectRatio: Double {
        let w = Double(width)
        let h = Double(height)
        return w > h ? w / h : h / w
    }

    var max: Int32 {
        Swift.max(width, height)
    }

    var sum: Int32 {
        width + height
    }

    // TODO: Find better name
    var area: Int32 {
        width * height
    }

    func aspectFit(size: Int32) -> Dimensions {
        let c = width >= height
        let r = c ? Double(height) / Double(width) : Double(width) / Double(height)
        return Dimensions(width: c ? size : Int32(r * Double(size)),
                          height: c ? Int32(r * Double(size)) : size)
    }

    // this may cause ambiguity
    // func diff(of dimensions: Dimensions) -> Dimensions {
    //    Dimensions(width: abs(self.width - dimensions.width),
    //               height: abs(self.height - dimensions.height))
    // }

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
                scaleDown: Double(max) / Double(preset.dimensions.max)
            )

            result.append(parameters)
        }
        return videoRids.map { rid in
            return result.first(where: { $0.rid == rid }) ?? Engine.createRtpEncodingParameters(rid: rid, active: false)
        }
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

    internal func videoLayers(for encodings: [RTCRtpEncodingParameters]) -> [Livekit_VideoLayer] {
        encodings.filter { $0.isActive }.map { encoding in
            let scaleDownBy = encoding.scaleResolutionDownBy?.doubleValue ?? 1.0
            return Livekit_VideoLayer.with {
                $0.width = UInt32((Double(self.width) / scaleDownBy).rounded(.up))
                $0.height = UInt32((Double(self.height) / scaleDownBy).rounded(.up))
                $0.quality = Livekit_VideoQuality.from(rid: encoding.rid)
                $0.bitrate = encoding.maxBitrateBps?.uint32Value ?? 0
            }
        }
    }
}

extension VideoEncoding {

}
