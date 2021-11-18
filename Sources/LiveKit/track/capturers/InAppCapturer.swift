import WebRTC
import ReplayKit
import Promises

@available(macOS 11.0, iOS 11.0, *)
class InAppScreenCapturer: VideoCapturer {

    func add(delegate: VideoCapturerDelegate) {
        //
    }

    func remove(delegate: VideoCapturerDelegate) {
        //
    }

    public var dimensions: Dimensions? {
        get {
            // TODO: Implement
            return nil
        }
    }

    func startCapture() -> Promise<Void> {
        return Promise { resolve, reject in
            // TODO: force pixel format kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            RPScreenRecorder.shared().startCapture { sampleBuffer, type, _ in
                if type == .video {
                    self.delegate?.capturer(self, didCapture: sampleBuffer)
                }
            } completionHandler: { error in
                if let error = error {
                    reject(error)
                    return
                }
                resolve(())
            }
        }
    }

    func stopCapture() -> Promise<Void> {
        return Promise { resolve, reject in
            RPScreenRecorder.shared().stopCapture { error in
                if let error = error {
                    reject(error)
                    return
                }
                resolve(())
            }

        }
    }
}

extension LocalVideoTrack {
    /// Creates a track that captures in-app screen only (due to limitation of ReplayKit)
    @available(macOS 11.0, iOS 11.0, *)
    public static func createInAppScreenShareTrack() -> LocalVideoTrack {
        let videoSource = Engine.factory.videoSource()
        let capturer = InAppScreenCapturer(delegate: videoSource)
        return LocalVideoTrack(
            capturer: capturer,
            videoSource: videoSource,
            name: Track.screenShareName,
            source: .screenShareVideo
        )
    }
}
