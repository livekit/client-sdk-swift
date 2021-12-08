import Foundation
import WebRTC

public struct ConnectOptions {
    public var autoSubscribe: Bool
    public var rtcConfiguration: RTCConfiguration
    public var protocolVersion: ProtocolVersion

    public init(autoSubscribe: Bool = true,
                rtcConfiguration: RTCConfiguration = .liveKitDefault(),
                protocolVersion: ProtocolVersion = .v5) {

        self.autoSubscribe = autoSubscribe
        self.rtcConfiguration = rtcConfiguration
        self.protocolVersion = protocolVersion
    }
}
