import Foundation
import WebRTC
import Promises

public class BufferCapturer: VideoCapturer {

    private let capturer = Engine.createVideoCapturer()

    /// The ``BufferCaptureOptions`` used for this capturer.
    public var options: BufferCaptureOptions

    init(delegate: RTCVideoCapturerDelegate, options: BufferCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    // shortcut
    public func capture(_ sampleBuffer: CMSampleBuffer) {

        delegate?.capturer(capturer, didCapture: sampleBuffer) { sourceDimensions in

            let targetDimensions = sourceDimensions
                .aspectFit(size: self.options.dimensions.max)
                .toEncodeSafeDimensions()

            if let videoSource = self.delegate as? RTCVideoSource {
                self.log("adapting to \(targetDimensions)")
                videoSource.adaptOutputFormat(toWidth: targetDimensions.width,
                                              height: targetDimensions.height,
                                              fps: Int32(self.options.fps))
            }

            self.dimensions = targetDimensions
        }
    }
}

extension LocalVideoTrack {

    /// Creates a track that can directly capture `CVPixelBuffer` or `CMSampleBuffer` for convienience
    public static func createBufferTrack(name: String = Track.screenShareName,
                                         source: VideoTrack.Source = .screenShareVideo,
                                         options: BufferCaptureOptions = BufferCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = BufferCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}
