import WebRTC

public typealias CaptureFunc = (_ capture: RTCVideoFrame) -> Void
public typealias InterceptFunc = (_ frame: RTCVideoFrame, _ capture: @escaping CaptureFunc) -> Void

public class VideoCaptureInterceptor: NSObject, RTCVideoCapturerDelegate {

    let output = Engine.createVideoSource(forScreenShare: true)
    let interceptFunc: InterceptFunc

    public init(_ interceptFunc: @escaping InterceptFunc) {
        self.interceptFunc = interceptFunc
        super.init()
        logger.debug("VideoCaptureInterceptor.init()")
    }

    deinit {
        logger.debug("VideoCaptureInterceptor.deinit()")
    }

    public func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {

        // create capture func to pass to intercept func
        let captureFunc = { [weak self, weak capturer] (frame: RTCVideoFrame) -> Void in
            guard let self = self,
                  let capturer = capturer else {
                return
            }

            // TODO: provide access to adaptOutputFormat
            // self.output.adaptOutputFormat(toWidth: 100, height: 100, fps: 15)
            self.output.capturer(capturer, didCapture: frame)
        }

        // call intercept func with frame & capture func
        interceptFunc(frame, captureFunc)
    }
}
