import Foundation

public class PublishOptions {

    public let name: String?

    internal init(name: String? = nil) {
        self.name = name
    }
}

public class VideoPublishOptions: PublishOptions {
    /// preferred encoding parameters
    public let encoding: VideoEncoding?
    /// encoding parameters for for screen share
    public let screenShareEncoding: VideoEncoding?
    /// true to enable simulcasting, publishes three tracks at different sizes
    public let simulcast: Bool

    public let simulcastLayers: [VideoParameters]

    public let screenShareSimulcastLayers: [VideoParameters]

    public init(encoding: VideoEncoding? = nil,
                screenShareEncoding: VideoEncoding? = nil,
                simulcast: Bool = true,
                simulcastLayers: [VideoParameters] = [],
                screenShareSimulcastLayers: [VideoParameters] = [.presetScreenShareH360FPS3, .presetScreenShareH720FPS5]) {

        self.encoding = encoding
        self.screenShareEncoding = screenShareEncoding
        self.simulcast = simulcast
        self.simulcastLayers = simulcastLayers
        self.screenShareSimulcastLayers = screenShareSimulcastLayers
    }
}

public class AudioPublishOptions: PublishOptions {

    public let bitrate: Int?
    public let dtx: Bool

    public init(name: String? = nil,
                bitrate: Int? = nil,
                dtx: Bool = true) {

        self.bitrate = bitrate
        self.dtx = dtx
        super.init(name: name)
    }
}

public class DataPublishOptions: PublishOptions {

}
