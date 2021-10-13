import WebRTC

extension Livekit_TrackType {

    func toLKType() -> Track.Kind {
        switch self {
        case .audio:
            return .audio
        case .video:
            return .video
        default:
            return .none
        }
    }
}

extension Track.Kind {

    func toPBType() -> Livekit_TrackType {
        switch self {
        case .audio:
            return .audio
        case .video:
            return .video
        default:
            return .UNRECOGNIZED(10)
        }
    }
}
