import WebRTC
import ReplayKit
import Dispatch

public class VideoBufferCapturer: RTCVideoCapturer {

    let source: RTCVideoSource

    public init(source: RTCVideoSource) {
        self.source = source
        super.init(delegate: source)
    }

    public func capture(pixelBuffer: CVPixelBuffer, timeStampNs: UInt64) {

        guard let delegate = delegate else {
            // if delegate is null, there's no reason to continue
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

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)

        let frame = RTCVideoFrame(buffer: rtcBuffer,
                                  rotation: ._0,
                                  timeStampNs: Int64(timeStampNs))

        delegate.capturer(self, didCapture: frame)
    }

    public func capture(sampleBuffer: CMSampleBuffer) {

        // check if buffer is ready
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = UInt64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        capture(pixelBuffer: pixelBuffer, timeStampNs: timeStampNs)
    }
}
