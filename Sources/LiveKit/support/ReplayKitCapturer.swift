import WebRTC
import ReplayKit
import Dispatch

public class ReplayKitCapturer: RTCVideoCapturer {

    let source: RTCVideoSource

    public init(source: RTCVideoSource) {
        self.source = source
        super.init(delegate: source)
    }

    public func encodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {

        // check if buffer is ready
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else {
                return
            }

        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // The source only supports NV12 (full-range) buffers.
        let pixelFormat = CVPixelBufferGetPixelFormatType(sourcePixelBuffer);
        if (pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            return
        }

        let width = CVPixelBufferGetWidth(sourcePixelBuffer);
        let height = CVPixelBufferGetHeight(sourcePixelBuffer);

        source.adaptOutputFormat(toWidth: Int32(width/2),
                                 height: Int32(height/2),
                                 fps: 15)

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ts2 = Int64(CMTimeGetSeconds(timestamp) * Double(NSEC_PER_SEC))

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: sourcePixelBuffer)

        let frame = RTCVideoFrame(buffer: rtcBuffer,
                                  rotation: ._0,
                                  timeStampNs: ts2)

        delegate?.capturer(self, didCapture: frame)
    }
}
