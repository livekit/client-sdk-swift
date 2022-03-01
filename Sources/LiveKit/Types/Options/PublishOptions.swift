import Foundation

public protocol PublishOptions {
    var name: String? { get }
}

public struct VideoPublishOptions: PublishOptions {

    public let name: String?
    /// preferred encoding parameters
    public let encoding: VideoEncoding?
    /// encoding parameters for for screen share
    public let screenShareEncoding: VideoEncoding?
    /// true to enable simulcasting, publishes three tracks at different sizes
    public let simulcast: Bool

    public let simulcastLayers: [VideoParameters]

    public let screenShareSimulcastLayers: [VideoParameters]

    public init(name: String? = nil,
                encoding: VideoEncoding? = nil,
                screenShareEncoding: VideoEncoding? = nil,
                simulcast: Bool = true,
                simulcastLayers: [VideoParameters] = [],
                screenShareSimulcastLayers: [VideoParameters] = []) {

        self.name = name
        self.encoding = encoding
        self.screenShareEncoding = screenShareEncoding
        self.simulcast = simulcast
        self.simulcastLayers = simulcastLayers
        self.screenShareSimulcastLayers = screenShareSimulcastLayers
    }
}

public struct AudioPublishOptions: PublishOptions {

    public let name: String?
    public let bitrate: Int?
    public let dtx: Bool

    public init(name: String? = nil,
                bitrate: Int? = nil,
                dtx: Bool = true) {

        self.name = name
        self.bitrate = bitrate
        self.dtx = dtx
    }
}

public struct DataPublishOptions: PublishOptions {

    public let name: String?

    public init(name: String? = nil) {

        self.name = name
    }
}
