import WebRTC

extension Livekit_StreamState {

    func toLKType() -> TrackPublication.StreamState {
        switch self {
        case .active: return .active
        default: return .paused
        }
    }
}
