import Foundation
import WebRTC

public struct ConnectOptions {

    public let autoSubscribe: Bool
    public let rtcConfiguration: RTCConfiguration
    public let protocolVersion: ProtocolVersion
    public let publish: String?

    public init(autoSubscribe: Bool = true,
                rtcConfiguration: RTCConfiguration = .liveKitDefault(),
                publish: String? = nil,
                protocolVersion: ProtocolVersion = .v6) {

        self.autoSubscribe = autoSubscribe
        self.rtcConfiguration = rtcConfiguration
        self.publish = publish
        self.protocolVersion = protocolVersion
    }
}
