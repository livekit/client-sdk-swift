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

    func computeSuggestedPresets(isScreenShare: Bool) -> [VideoParameters] {
        if isScreenShare {
            return VideoParameters.presetsScreenShare
        }
        if abs(aspectRatio - Dimensions.aspectRatio169) < abs(aspectRatio - Dimensions.aspectRatio43) {
            return VideoParameters.presets169
        }
        return VideoParameters.presets43
    }

    func defaultSimulcastLayers(isScreenShare: Bool) -> [VideoParameters] {
        if isScreenShare {
            return []
        }
        if abs(aspectRatio - Dimensions.aspectRatio169) < abs(aspectRatio - Dimensions.aspectRatio43) {
            return VideoParameters.defaultSimulcastPresets169
        }
        return VideoParameters.defaultSimulcastPresets43
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

// MARK: - Presets

public extension Dimensions {

    // 16:9 aspect ratio presets
    static let h90_169 = Dimensions(width: 160, height: 90)
    static let h180_169 = Dimensions(width: 320, height: 180)
    static let h216_169 = Dimensions(width: 384, height: 216)
    static let h360_169 = Dimensions(width: 640, height: 360)
    static let h540_169 = Dimensions(width: 960, height: 540)
    static let h720_169 = Dimensions(width: 1_280, height: 720)
    static let h1080_169 = Dimensions(width: 1_920, height: 1_080)
    static let h1440_169 = Dimensions(width: 2_560, height: 1_440)
    static let h2160_169 = Dimensions(width: 3_840, height: 2_160)

    // 4:3 aspect ratio presets
    static let h120_43 = Dimensions(width: 160, height: 120)
    static let h180_43 = Dimensions(width: 240, height: 180)
    static let h240_43 = Dimensions(width: 320, height: 240)
    static let h360_43 = Dimensions(width: 480, height: 360)
    static let h480_43 = Dimensions(width: 640, height: 480)
    static let h540_43 = Dimensions(width: 720, height: 540)
    static let h720_43 = Dimensions(width: 960, height: 720)
    static let h1080_43 = Dimensions(width: 1_440, height: 1_080)
    static let h1440_43 = Dimensions(width: 1_920, height: 1_440)
}

// MARK: - Deprecated

@available(*, deprecated)
public extension Dimensions {

    // 16:9 aspect ratio presets
    static let qvga169 = h180_169
    static let vga169 = h360_169
    static let qhd169 = h540_169
    static let hd169 = h720_169
    static let fhd169 = h1080_169

    // 4:3 aspect ratio presets
    static let qvga43 = h180_43
    static let vga43 = h360_43
    static let qhd43 = h540_43
    static let hd43 = h720_43
    static let fhd43 = h1080_43
}
