import Foundation
import WebRTC

public typealias Sid = String

public enum ConnectionState {
    case disconnected
    case connecting(reconnecting: Bool)
//    case reconnecting
    case connected
}

extension ConnectionState: Equatable {

    public static func ==(lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (let .connecting(a1), let .connecting(a2)): return a1 == a2
        case (.disconnected, .disconnected): return true
        case (.connected, .connected): return true
        default: return false
        }
    }
}

public struct Dimensions {
    public static let aspectRatio169 = 16.0 / 9.0
    public static let aspectRatio43 = 4.0 / 3.0

    public let width: Int
    public let height: Int
}

public enum ProtocolVersion {
    case v2
    case v3
}

extension ProtocolVersion: CustomStringConvertible {

    public var description: String {
        switch self {
        case .v2:
            return "2"
        case .v3:
            return "3"
        }
    }
}
