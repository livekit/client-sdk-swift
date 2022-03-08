import Foundation
import WebRTC

/// Options used when establishing a connection.
public struct ConnectOptions {

    /// Automatically subscribe to ``RemoteParticipant``'s tracks.
    /// Defaults to true.
    public let autoSubscribe: Bool
    public let rtcConfiguration: RTCConfiguration
    /// LiveKit server protocol version to use. Generally, it's not recommended to change this.
    public let protocolVersion: ProtocolVersion
    /// Providing a string will make the connection publish-only, suitable for iOS Broadcast Upload Extensions.
    /// The string can be used to identify the publisher.
    public let publishOnlyMode: String?

    public init(autoSubscribe: Bool = true,
                rtcConfiguration: RTCConfiguration = .liveKitDefault(),
                publishOnlyMode: String? = nil,
                protocolVersion: ProtocolVersion = .v6) {

        self.autoSubscribe = autoSubscribe
        self.rtcConfiguration = rtcConfiguration
        self.publishOnlyMode = publishOnlyMode
        self.protocolVersion = protocolVersion
    }
}
