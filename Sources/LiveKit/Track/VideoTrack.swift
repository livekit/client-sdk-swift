import WebRTC

public protocol VideoTrack: Track {

}

extension VideoTrack {

    public func add(renderer: RTCVideoRenderer) {
        guard let videoTrack = mediaTrack as? RTCVideoTrack else { return }
        DispatchQueue.webRTC.sync { videoTrack.add(renderer) }
    }

    public func remove(renderer: RTCVideoRenderer) {
        guard let videoTrack = mediaTrack as? RTCVideoTrack else { return }
        DispatchQueue.webRTC.sync { videoTrack.remove(renderer) }
    }
}
