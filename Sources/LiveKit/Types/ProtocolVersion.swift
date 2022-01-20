import Foundation

public enum ProtocolVersion {
    case v2
    case v3
    case v4
    case v5
    case v6
}

extension ProtocolVersion: CustomStringConvertible {

    public var description: String {
        switch self {
        case .v2: return "2"
        case .v3: return "3"
        case .v4: return "4"
        case .v5: return "5"
        case .v6: return "6"
        }
    }
}
