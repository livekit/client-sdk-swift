import Foundation

public class PublishOptions {

    public let name: String?

    internal init(name: String? = nil) {
        self.name = name
    }
}

public class VideoPublishOptions: PublishOptions {

    public let encoding: VideoEncoding?
    /// true to enable simulcasting, publishes three tracks at different sizes
    public let simulcast: Bool

    public init(encoding: VideoEncoding? = nil,
                simulcast: Bool = true) {

        self.encoding = encoding
        self.simulcast = simulcast
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
