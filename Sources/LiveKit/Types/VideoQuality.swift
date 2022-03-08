internal enum VideoQuality {
    case low
    case medium
    case high
}

internal extension VideoQuality {

    static let rids = ["q", "h", "f"]
}

internal extension VideoQuality {

    private static let toPBTypeMap: [VideoQuality: Livekit_VideoQuality] = [
        .low: .low,
        .medium: .medium,
        .high: .high
    ]

    func toPBType() -> Livekit_VideoQuality {
        return Self.toPBTypeMap[self] ?? .high
    }
}

internal extension Livekit_VideoQuality {

    private static let toSDKTypeMap: [Livekit_VideoQuality: VideoQuality] = [
        .low: .low,
        .medium: .medium,
        .high: .high
    ]

    func toSDKType() -> VideoQuality {
        return Self.toSDKTypeMap[self] ?? .high
    }

    static func from(rid: String?) -> Livekit_VideoQuality {
        switch rid {
        case "h": return Livekit_VideoQuality.medium
        case "q": return Livekit_VideoQuality.low
        default: return Livekit_VideoQuality.high
        }
    }
}
