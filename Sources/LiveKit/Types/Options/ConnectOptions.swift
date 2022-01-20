import Foundation
import WebRTC

public class ConnectOptions {
    public var autoSubscribe: Bool
    public var rtcConfiguration: RTCConfiguration
    public var protocolVersion: ProtocolVersion
    public var publish: String?

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
