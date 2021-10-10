import Foundation

public struct ConnectOptions {
    public var accessToken: String
    public var url: String
    public var autoSubscribe: Bool
    public var protocolVersion: ProtocolVersion

    public init(url: String,
                token: String,
                autoSubscribe: Bool = true,
                protocolVersion: ProtocolVersion = .v3) {

        self.accessToken = token
        self.url = url
        self.autoSubscribe = autoSubscribe
        self.protocolVersion = protocolVersion
    }
}

public struct LocalAudioTrackPublishOptions {
    public var name: String?
    public var bitrate: Int?

    public init() {}
}

public struct LocalVideoTrackPublishOptions {
    public var encoding: VideoEncoding?
    /// true to enable simulcasting, publishes three tracks at different sizes
    public var simulcast: Bool = false

    public init() {}
}

public struct LocalDataTrackPublishOptions {
    public var name: String?
}

public struct VideoEncoding {
    public var maxBitrate: Int
    public var maxFps: Int

    public init(maxBitrate: Int, maxFps: Int) {
        self.maxBitrate = maxBitrate
        self.maxFps = maxFps
    }
}

public enum DataPublishReliability: Int {
    case reliable = 0
    case lossy = 1
}
