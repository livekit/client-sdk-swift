import WebRTC
import ReplayKit

extension CGImagePropertyOrientation {

    public func toRTCRotation() -> RTCVideoRotation {
        switch self {
        case .up, .upMirrored, .down, .downMirrored: return ._0
        case .left, .leftMirrored: return ._90
        case .right, .rightMirrored: return ._270
        default: return ._0
        }
    }
}

extension RTCVideoCapturerDelegate {

    /// capture a `CVPixelBuffer`
    public func capturer(_ capturer: RTCVideoCapturer,
                         didCapture pixelBuffer: CVPixelBuffer,
                         timeStampNs: UInt64,
                         rotation: RTCVideoRotation = ._0) {

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // RTCCameraVideoCapturer.preferredOutputPixelFormat reports kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange.
        if [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].contains(pixelFormat) {
            // logger.debug("Capturing in pixel format \(pixelFormat.toString())")
        } else {
            // The source only supports NV12 (full-range) buffers.
            logger.warning("Capturing in pixel format unknown to be supported by WebRTC \(pixelFormat.toString())")
        }

        DispatchQueue.webRTC.sync {

            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)

            let frame = RTCVideoFrame(buffer: rtcBuffer,
                                      rotation: rotation,
                                      timeStampNs: Int64(timeStampNs))

            self.capturer(capturer, didCapture: frame)
        }
    }

    /// capture a `CMSampleBuffer`
    public func capturer(_ capturer: RTCVideoCapturer,
                         didCapture sampleBuffer: CMSampleBuffer,
                         withPixelBuffer: ((CVPixelBuffer) -> Void)? = nil) {

        // check if buffer is ready
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else {
            logger.warning("Failed to capture, buffer is not ready")
            return
        }

        // attempt to determine rotation information if buffer is coming from ReplayKit
        var rotation: RTCVideoRotation?
        if #available(macOS 11.0, *) {
            // Check rotation tags. Extensions see these tags, but `RPScreenRecorder` does not appear to set them.
            // On iOS 12.0 and 13.0 rotation tags (other than up) are set by extensions.
            if let sampleOrientation = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil),
               let coreSampleOrientation = sampleOrientation.uint32Value {
                rotation = CGImagePropertyOrientation(rawValue: coreSampleOrientation)?.toRTCRotation()
            }
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.warning("Failed to capture, pixel buffer not found")
            return
        }

        withPixelBuffer?(pixelBuffer)

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = UInt64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        self.capturer(capturer,
                      didCapture: pixelBuffer,
                      timeStampNs: timeStampNs,
                      rotation: rotation ?? ._0)
    }
}

extension CVPixelBuffer {

    func toDimensions() -> Dimensions {
        Dimensions(width: Int32(CVPixelBufferGetWidth(self)),
                   height: Int32(CVPixelBufferGetHeight(self)))
    }
}
