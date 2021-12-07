import Foundation

public struct ConnectOptions {
    public var autoSubscribe: Bool
    public var protocolVersion: ProtocolVersion

    public var defaultVideoPublishOptions: LocalVideoTrackPublishOptions
    public var defaultAudioPublishOptions: LocalAudioTrackPublishOptions

    public var stopLocalTrackOnUnpublish: Bool

    public init(autoSubscribe: Bool = true,
                defaultVideoPublishOptions: LocalVideoTrackPublishOptions = LocalVideoTrackPublishOptions(),
                defaultAudioPublishOptions: LocalAudioTrackPublishOptions = LocalAudioTrackPublishOptions(),
                stopLocalTrackOnUnpublish: Bool = true,
                protocolVersion: ProtocolVersion = .v5) {

        self.autoSubscribe = autoSubscribe
        self.defaultVideoPublishOptions = defaultVideoPublishOptions
        self.defaultAudioPublishOptions = defaultAudioPublishOptions
        self.stopLocalTrackOnUnpublish = stopLocalTrackOnUnpublish
        self.protocolVersion = protocolVersion
    }
}
