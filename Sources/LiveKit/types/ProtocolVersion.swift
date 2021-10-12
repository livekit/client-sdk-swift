import Foundation

public enum ProtocolVersion {
    case v2
    case v3
}

extension ProtocolVersion: CustomStringConvertible {

    public var description: String {
        switch self {
        case .v2: return "2"
        case .v3: return "3"
        }
    }
}
