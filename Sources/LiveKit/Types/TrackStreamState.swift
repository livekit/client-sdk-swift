import WebRTC

public enum StreamState {
    case paused
    case active
}

extension Livekit_StreamState {

    func toLKType() -> StreamState {
        switch self {
        case .active: return .active
        default: return .paused
        }
    }
}
