import Foundation

public struct ConnectOptions {
    public var autoSubscribe: Bool
    public var protocolVersion: ProtocolVersion

    public var defaultVideoPublishOptions: LocalVideoTrackPublishOptions
    public var defaultAudioPublishOptions: LocalAudioTrackPublishOptions

    public init(autoSubscribe: Bool = true,
                defaultVideoPublishOptions: LocalVideoTrackPublishOptions = LocalVideoTrackPublishOptions(),
                defaultAudioPublishOptions: LocalAudioTrackPublishOptions = LocalAudioTrackPublishOptions(),
                protocolVersion: ProtocolVersion = .v4) {

        self.autoSubscribe = autoSubscribe
        self.defaultVideoPublishOptions = defaultVideoPublishOptions
        self.defaultAudioPublishOptions = defaultAudioPublishOptions
        self.protocolVersion = protocolVersion
    }
}
