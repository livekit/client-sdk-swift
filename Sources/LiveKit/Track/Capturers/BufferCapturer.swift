import Foundation
import WebRTC
import Promises

public class BufferCapturer: VideoCapturer {

    private let capturer = Engine.createVideoCapturer()

    // shortcut
    public func capture(_ sampleBuffer: CMSampleBuffer,
                        scale: Double = 1) {

        delegate?.capturer(capturer,
                           didCapture: sampleBuffer,
                           scale: scale) { targetDimensions in

            // report dimensions update
            self.dimensions = targetDimensions
        }
    }
}

extension LocalVideoTrack {

    /// Creates a track that can directly capture `CVPixelBuffer` or `CMSampleBuffer` for convienience
    public static func createBufferTrack(name: String = Track.screenShareName,
                                         source: VideoTrack.Source = .screenShareVideo) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = BufferCapturer(delegate: videoSource)
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}
