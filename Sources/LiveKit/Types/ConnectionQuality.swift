public enum ConnectionQuality {
    case unknown
    case poor
    case good
    case excellent
}

extension Livekit_ConnectionQuality {

    func toLKType() -> ConnectionQuality {
        switch self {
        case .poor: return .poor
        case .good: return .good
        case .excellent: return .excellent
        default: return .unknown
        }
    }
}
