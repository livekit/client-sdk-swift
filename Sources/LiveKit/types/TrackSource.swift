
extension Livekit_TrackSource {
    
    func toLKType() -> Track.Source {
        switch self {
        case .camera: return .camera
        case .microphone: return .microphone
        case .screenShare: return .screenShare
        default: return .unknown
        }
    }
}

extension Track.Source {
    
    func toPBType() -> Livekit_TrackSource {
        switch self {
        case .camera: return .camera
        case .microphone: return .microphone
        case .screenShare: return .screenShare
        default: return .unknown
        }
    }
}
