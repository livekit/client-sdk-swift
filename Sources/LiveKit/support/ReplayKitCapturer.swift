import WebRTC
import ReplayKit
import Dispatch

public class ReplayKitCapturer: RTCVideoCapturer {

    let source: RTCVideoSource

    public init(source: RTCVideoSource) {
        self.source = source
        super.init(delegate: source)
    }

    public func encodeSampleBuffer(_ buffer: CMSampleBuffer) {

        guard let delegate = delegate else {
            // if delegate is null, there's no reason to continue
            return
        }

        // check if buffer is ready
        guard CMSampleBufferGetNumSamples(buffer) == 1,
              CMSampleBufferIsValid(buffer),
              CMSampleBufferDataIsReady(buffer) else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            return
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            // The source only supports NV12 (full-range) buffers.
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // TODO: improve, support rotation etc.
        source.adaptOutputFormat(toWidth: Int32(width/2),
                                 height: Int32(height/2),
                                 fps: 15)

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)

        let frame = RTCVideoFrame(buffer: rtcBuffer,
                                  rotation: ._0,
                                  timeStampNs: timeStampNs)

        delegate.capturer(self, didCapture: frame)
    }
}
