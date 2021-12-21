import WebRTC
import Promises

class RemoteVideoTrack: RemoteTrack, VideoTrack {

    init(name: String,
         source: Track.Source,
         track: RTCMediaStreamTrack) {

        super.init(name: name,
                   kind: .video,
                   source: source,
                   track: track)
    }
}
