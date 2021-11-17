import Foundation
import WebRTC
import Promises

class BufferCapturer: VideoCapturer {

    func startCapture() -> Promise<Void> {
        // nothing to do for now
        Promise(())
    }

    func stopCapture() -> Promise<Void> {
        // nothing to do for now
        Promise(())
    }

    // shortcut
    func capture(_ sampleBuffer: CMSampleBuffer) {
        delegate?.capturer(self, didCapture: sampleBuffer)
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
