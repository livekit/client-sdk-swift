//
// LiveKit
// https://livekit.io
//

import WebRTC

extension Livekit_ICEServer {

    func toRTCType() -> RTCIceServer {
        let rtcUsername = !username.isEmpty ? username : nil
        let rtcCredential = !credential.isEmpty ? credential : nil
        return RTCIceServer(urlStrings: urls, username: rtcUsername, credential: rtcCredential)
    }
}

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
