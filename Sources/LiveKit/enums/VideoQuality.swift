import Foundation

public enum VideoQuality {
    case low
    case medium
    case high
}

extension VideoQuality {

    internal func toPBType() -> Livekit_VideoQuality {
        switch self {
        case .low:
            return .low
        case .high:
            return .high
        default:
            return .medium
        }
    }
}

extension Livekit_VideoQuality {

    internal func toLKType() -> VideoQuality {
        switch self {
        case .low:
            return .low
        case .high:
            return .high
        default:
            return .medium
        }
    }
}
