import Foundation

public struct ConnectOptions {
    public var protocolVersion: ProtocolVersion
    public var autoSubscribe: Bool

    public init(autoSubscribe: Bool = true,
                protocolVersion: ProtocolVersion = .v5) {

        self.autoSubscribe = autoSubscribe
        self.protocolVersion = protocolVersion
    }
}
