import WebRTC

public protocol VideoTrack: Track {

}

extension VideoTrack {

    public func addRenderer(_ renderer: RTCVideoRenderer) {
        guard let videoTrack = mediaTrack as? RTCVideoTrack else { return }
        videoTrack.add(renderer)
    }

    public func removeRenderer(_ renderer: RTCVideoRenderer) {
        guard let videoTrack = mediaTrack as? RTCVideoTrack else { return }
        videoTrack.remove(renderer)
    }
}
