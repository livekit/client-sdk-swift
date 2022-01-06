import WebRTC
import ReplayKit
import Promises

@available(macOS 11.0, iOS 11.0, *)
public class InAppScreenCapturer: VideoCapturer {

    private let capturer = RTCVideoCapturer()

    public override func startCapture() -> Promise<Void> {
        return super.startCapture().then {

            Promise { resolve, fail in
                // TODO: force pixel format kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                RPScreenRecorder.shared().startCapture { sampleBuffer, type, _ in
                    if type == .video {
                        self.delegate?.capturer(self.capturer, didCapture: sampleBuffer) { pixelBuffer in
                            // report dimensions update
                            self.dimensions = pixelBuffer.toDimensions()
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
        return super.stopCapture().then {
            Promise { resolve, fail in
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
    public static func createInAppScreenShareTrack() -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = InAppScreenCapturer(delegate: videoSource)
        return LocalVideoTrack(
            name: Track.screenShareName,
            source: .screenShareVideo,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}
