import Foundation

public struct LocalVideoTrackPublishOptions {
    public var encoding: VideoEncoding?
    /// true to enable simulcasting, publishes three tracks at different sizes
    public var simulcast: Bool

    public init(encoding: VideoEncoding? = nil, simulcast: Bool = true) {
        self.encoding = encoding
        self.simulcast = simulcast
    }
}

public struct LocalAudioTrackPublishOptions {
    public var name: String?
    public var bitrate: Int?
    public var dtx: Bool

    public init(dtx: Bool = true) {
        self.dtx = dtx
    }
}

public struct LocalDataTrackPublishOptions {
    public var name: String?
}
