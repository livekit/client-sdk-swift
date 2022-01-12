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

internal let supportedPixelFormats = DispatchQueue.webRTC.sync { RTCCVPixelBuffer.supportedPixelFormats() }

extension RTCVideoCapturerDelegate {

    /// capture a `CVPixelBuffer`
    public func capturer(_ capturer: RTCVideoCapturer,
                         didCapture pixelBuffer: CVPixelBuffer,
                         timeStampNs: UInt64,
                         rotation: RTCVideoRotation = ._0,
                         scale: Double = 1.0) {

        // check if pixel format is supported by WebRTC
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard supportedPixelFormats.contains(where: { $0.uint32Value == pixelFormat }) else {
            // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            // kCVPixelFormatType_32BGRA
            // kCVPixelFormatType_32ARGB
            logger.warning("Unsupported pixel format \(pixelFormat.toString())")
            return
        }

        let height = CVPixelBufferGetHeight(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)

        DispatchQueue.webRTC.sync {

            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer,
                                             adaptedWidth: Int32((Double(width) * scale).rounded()),
                                             adaptedHeight: Int32((Double(height) * scale).rounded()),
                                             cropWidth: Int32(width),
                                             cropHeight: Int32(height),
                                             cropX: 0,
                                             cropY: 0)

            let frame = RTCVideoFrame(buffer: rtcBuffer,
                                      rotation: rotation,
                                      timeStampNs: Int64(timeStampNs))

            self.capturer(capturer, didCapture: frame)
        }
    }

    /// capture a `CMSampleBuffer`
    public func capturer(_ capturer: RTCVideoCapturer,
                         didCapture sampleBuffer: CMSampleBuffer,
                         scale: Double = 1,
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
                      rotation: rotation ?? ._0,
                      scale: scale)
    }
}

extension CVPixelBuffer {

    func toDimensions() -> Dimensions {
        Dimensions(width: Int32(CVPixelBufferGetWidth(self)),
                   height: Int32(CVPixelBufferGetHeight(self)))
    }
}
