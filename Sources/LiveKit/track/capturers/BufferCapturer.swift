import Foundation
import WebRTC
import Promises

class BufferCapturer: VideoCapturer {

    private let capturer = RTCVideoCapturer()

    // shortcut
    func capture(_ sampleBuffer: CMSampleBuffer) {
        delegate?.capturer(capturer, didCapture: sampleBuffer)
    }
}

extension LocalVideoTrack {

    /// Creates a track that can directly capture `CVPixelBuffer` or `CMSampleBuffer` for convienience
    public static func createBufferTrack(name: String = Track.screenShareName,
                                         source: VideoTrack.Source = .screenShareVideo) -> LocalVideoTrack {
        let videoSource = Engine.factory.videoSource()
        let capturer = BufferCapturer(delegate: videoSource)
        return LocalVideoTrack(
            capturer: capturer,
            videoSource: videoSource,
            name: name,
            source: source
        )
    }
}
