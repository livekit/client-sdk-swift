extension Livekit_TrackSource {

    func toLKType() -> Track.Source {
        switch self {
        case .camera: return .camera
        case .microphone: return .microphone
        case .screenShare: return .screenShareVideo
        case .screenShareAudio: return .screenShareAudio
        default: return .unknown
        }
    }
}

extension Track.Source {

    func toPBType() -> Livekit_TrackSource {
        switch self {
        case .camera: return .camera
        case .microphone: return .microphone
        case .screenShareVideo: return .screenShare
        case .screenShareAudio: return .screenShareAudio
        default: return .unknown
        }
    }
}
