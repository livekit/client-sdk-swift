import Foundation

public struct LocalVideoTrackPublishOptions {
    public var encoding: VideoEncoding?
    /// true to enable simulcasting, publishes three tracks at different sizes
    public var simulcast: Bool = false

    public init() {}
}

public struct LocalAudioTrackPublishOptions {
    public var name: String?
    public var bitrate: Int?

    public init() {}
}

public struct LocalDataTrackPublishOptions {
    public var name: String?
}
