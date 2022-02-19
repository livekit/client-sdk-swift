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

extension VideoEncoding: Comparable {

    public static func < (lhs: VideoEncoding, rhs: VideoEncoding) -> Bool {

        if lhs.maxBitrate == rhs.maxBitrate {
            return lhs.maxFps < rhs.maxFps
        }

        return lhs.maxBitrate < rhs.maxBitrate
    }
}
