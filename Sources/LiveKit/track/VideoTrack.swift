import Foundation
import WebRTC

public class VideoTrack: Track {
    public var videoTrack: RTCVideoTrack {
        get { return mediaTrack as! RTCVideoTrack }
    }

    init(rtcTrack: RTCVideoTrack, name: String) {
        super.init(name: name, kind: .video, track: rtcTrack)
    }

    public func addRenderer(_ renderer: RTCVideoRenderer) {
        videoTrack.add(renderer)
    }

    public func removeRenderer(_ renderer: RTCVideoRenderer) {
        videoTrack.remove(renderer)
    }
}
