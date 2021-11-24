import Foundation
import WebRTC

public struct VideoEncoding {
    public var maxBitrate: Int
    public var maxFps: Int

    public init(maxBitrate: Int, maxFps: Int) {
        self.maxBitrate = maxBitrate
        self.maxFps = maxFps
    }
}

extension RTCRtpEncodingParameters {

    convenience init(rid: String? = nil,
                     encoding: VideoEncoding? = nil,
                     scaleDown: Double = 1.0,
                     active: Bool = true) {
        self.init()
        self.isActive = active
        self.rid = rid
        self.scaleResolutionDownBy = NSNumber(value: scaleDown)

        if let encoding = encoding {
            self.maxFramerate = NSNumber(value: encoding.maxFps)
            self.maxBitrateBps = NSNumber(value: encoding.maxBitrate)
        }
    }
}

extension VideoEncoding {

    func toRTCRtpEncoding(
        rid: String? = nil,
        scaleDownBy: Double = 1.0
    ) -> RTCRtpEncodingParameters {

        let result = RTCRtpEncodingParameters()
        result.isActive = true

        if let rid = rid {
            result.rid = rid
        }

        // int
        result.numTemporalLayers = NSNumber(value: 1)
        // double
        result.scaleResolutionDownBy = NSNumber(value: scaleDownBy)
        // int
        result.maxFramerate = NSNumber(value: maxFps)
        // int
        result.maxBitrateBps = NSNumber(value: maxBitrate) // 500 * 1024

        // only set on the full track
        if scaleDownBy == 1 {
            result.networkPriority = .high
            result.bitratePriority = 4.0
        } else {
            result.networkPriority = .low
            result.bitratePriority = 1.0
        }

        return result
    }
}
