import WebRTC
import ReplayKit
import Promises

@available(macOS 11.0, iOS 11.0, *)
class InAppScreenCapturer: VideoCapturer {

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
