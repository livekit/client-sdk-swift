import Foundation
import WebRTC
import Promises

public class BufferCapturer: VideoCapturer {

    private let capturer = Engine.createVideoCapturer()

    /// The ``ScreenShareCaptureOptions`` used for this capturer.
    /// It is possible to modify the options but `restartCapture` must be called.
    public var options: ScreenShareCaptureOptions

    init(delegate: RTCVideoCapturerDelegate, options: ScreenShareCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    // shortcut
    public func capture(_ sampleBuffer: CMSampleBuffer) {

        delegate?.capturer(capturer, didCapture: sampleBuffer) { sourceDimensions in

            let targetDimensions = sourceDimensions.aspectFit(size: 1080).toEncodeSafeDimensions()

            if let videoSource = self.delegate as? RTCVideoSource {
                self.log("adapting to \(targetDimensions)")
                videoSource.adaptOutputFormat(toWidth: targetDimensions.width,
                                              height: targetDimensions.height,
                                              fps: Int32(24))
            }

            self.dimensions = targetDimensions
        }
    }
}

extension LocalVideoTrack {

    /// Creates a track that can directly capture `CVPixelBuffer` or `CMSampleBuffer` for convienience
    public static func createBufferTrack(name: String = Track.screenShareName,
                                         source: VideoTrack.Source = .screenShareVideo,
                                         options: ScreenShareCaptureOptions = ScreenShareCaptureOptions()) -> LocalVideoTrack {
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
