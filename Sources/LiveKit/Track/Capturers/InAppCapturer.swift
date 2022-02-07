import WebRTC
import ReplayKit
import Promises

@available(macOS 11.0, iOS 11.0, *)
public class InAppScreenCapturer: VideoCapturer {

    private let capturer = Engine.createVideoCapturer()
    private var options: ScreenShareCaptureOptions

    init(delegate: RTCVideoCapturerDelegate, options: ScreenShareCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    public override func startCapture() -> Promise<Void> {
        return super.startCapture().then(on: .sdk) {
            Promise(on: .sdk) { resolve, fail in
                // TODO: force pixel format kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                RPScreenRecorder.shared().startCapture { sampleBuffer, type, _ in
                    if type == .video {

                        self.delegate?.capturer(self.capturer, didCapture: sampleBuffer) { sourceDimensions in

                            let targetDimensions = sourceDimensions
                                .aspectFit(size: self.options.dimensions.max)
                                .toEncodeSafeDimensions()

                            guard let videoSource = self.delegate as? RTCVideoSource else { return }
                            videoSource.adaptOutputFormat(toWidth: targetDimensions.width,
                                                          height: targetDimensions.height,
                                                          fps: Int32(self.options.fps))

                            self.dimensions = targetDimensions
                        }
                    }
                } completionHandler: { error in
                    if let error = error {
                        fail(error)
                        return
                    }
                    resolve(())
                }
            }
        }
    }

    public override func stopCapture() -> Promise<Void> {
        return super.stopCapture().then(on: .sdk) {
            Promise(on: .sdk) { resolve, fail in
                RPScreenRecorder.shared().stopCapture { error in
                    if let error = error {
                        fail(error)
                        return
                    }
                    resolve(())
                }

            }
        }
    }
}

extension LocalVideoTrack {
    /// Creates a track that captures in-app screen only (due to limitation of ReplayKit)
    @available(macOS 11.0, iOS 11.0, *)
    public static func createInAppScreenShareTrack(options: ScreenShareCaptureOptions = ScreenShareCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = InAppScreenCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(
            name: Track.screenShareName,
            source: .screenShareVideo,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}
