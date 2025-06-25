/*
 * Copyright 2025 LiveKit
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

import CoreMedia

internal import LiveKitWebRTC

@objc
public final class Dimensions: NSObject, Loggable, Sendable {
    @objc
    public let width: Int32

    @objc
    public let height: Int32

    @objc
    public init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }

    public init(from dimensions: CMVideoDimensions) {
        width = dimensions.width
        height = dimensions.height
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return width == other.width && height == other.height
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(width)
        hasher.combine(height)
        return hasher.finalize()
    }

    override public var description: String {
        "Dimensions(\(width)x\(height))"
    }
}

// MARK: - Static constants

public extension Dimensions {
    static let aspectRatio169 = 16.0 / 9.0
    static let aspectRatio43 = 4.0 / 3.0
    static let zero = Dimensions(width: 0, height: 0)

    internal static let renderSafeSize: Int32 = 8
    internal static let encodeSafeSize: Int32 = 16
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

    // TODO: Find better name
    var area: Int32 {
        width * height
    }

    func swapped() -> Dimensions {
        Dimensions(width: height, height: width)
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

    func computeSuggestedPreset(in presets: [VideoParameters]) -> VideoEncoding {
        if presets.isEmpty {
            log("presets is empty", .error)
        }

        var result = presets[0].encoding
        for preset in presets {
            result = preset.encoding
            if preset.dimensions.width >= max {
                break
            }
        }
        return result
    }

    func encodings(from presets: [VideoParameters?]) -> [LKRTCRtpEncodingParameters] {
        var result: [LKRTCRtpEncodingParameters] = []
        for (index, preset) in presets.compactMap({ $0 }).enumerated() {
            guard let rid = VideoQuality.RIDs[safe: index] else {
                continue
            }

            let parameters = RTC.createRtpEncodingParameters(
                rid: rid,
                encoding: preset.encoding,
                scaleDownBy: Double(max) / Double(preset.dimensions.max)
            )

            result.append(parameters)
        }

        return VideoQuality.RIDs.compactMap { rid in result.first(where: { $0.rid == rid }) }
    }

    func videoLayers(for encodings: [LKRTCRtpEncodingParameters]) -> [Livekit_VideoLayer] {
        if let firstEncoding = encodings.first,
           let scalabilityMode = ScalabilityMode.fromString(firstEncoding.scalabilityMode)
        {
            (0 ... (scalabilityMode.spatial - 1)).map { idx in
                Livekit_VideoLayer.with {
                    $0.width = UInt32((Double(width) / pow(2, Double(idx))).rounded(.down))
                    $0.height = UInt32((Double(height) / pow(2, Double(idx))).rounded(.down))
                    $0.quality = Livekit_VideoQuality(rawValue: scalabilityMode.spatial - idx - 1) ?? .off
                    $0.bitrate = UInt32((Double(truncating: firstEncoding.maxBitrateBps ?? 0) / pow(3, Double(idx))).rounded(.up))
                }
            }

        } else {
            encodings.filter(\.isActive).map { encoding in
                let scaleDownBy = encoding.scaleResolutionDownBy?.doubleValue ?? 1.0
                return Livekit_VideoLayer.with {
                    $0.width = UInt32((Double(width) / scaleDownBy).rounded(.down))
                    $0.height = UInt32((Double(height) / scaleDownBy).rounded(.down))
                    $0.quality = Livekit_VideoQuality.from(rid: encoding.rid) ?? .high
                    $0.bitrate = encoding.maxBitrateBps?.uint32Value ?? 0
                }
            }
        }
    }
}

// MARK: - Convert

extension Dimensions {
    func apply(rotation: LKRTCVideoRotation) -> Dimensions {
        if rotation == ._90 || rotation == ._270 {
            return swapped()
        }

        return self
    }
}

// MARK: - Presets

@objc
public extension Dimensions {
    // 16:9 aspect ratio presets
    static let h90_169 = Dimensions(width: 160, height: 90)

    static let h180_169 = Dimensions(width: 320, height: 180)

    static let h216_169 = Dimensions(width: 384, height: 216)

    static let h360_169 = Dimensions(width: 640, height: 360)

    static let h540_169 = Dimensions(width: 960, height: 540)

    static let h720_169 = Dimensions(width: 1280, height: 720)

    static let h1080_169 = Dimensions(width: 1920, height: 1080)

    static let h1440_169 = Dimensions(width: 2560, height: 1440)

    static let h2160_169 = Dimensions(width: 3840, height: 2160)

    // 4:3 aspect ratio presets
    static let h120_43 = Dimensions(width: 160, height: 120)

    static let h180_43 = Dimensions(width: 240, height: 180)

    static let h240_43 = Dimensions(width: 320, height: 240)

    static let h360_43 = Dimensions(width: 480, height: 360)

    static let h480_43 = Dimensions(width: 640, height: 480)

    static let h540_43 = Dimensions(width: 720, height: 540)

    static let h720_43 = Dimensions(width: 960, height: 720)

    static let h1080_43 = Dimensions(width: 1440, height: 1080)

    static let h1440_43 = Dimensions(width: 1920, height: 1440)
}
