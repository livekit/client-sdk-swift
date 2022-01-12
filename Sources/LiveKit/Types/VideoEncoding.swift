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
