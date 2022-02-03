import WebRTC
import ReplayKit

extension FixedWidthInteger {

    func roundUp(toMultipleOf powerOfTwo: Self) -> Self {
        // Check that powerOfTwo really is.
        precondition(powerOfTwo > 0 && powerOfTwo & (powerOfTwo &- 1) == 0)
        // Round up and return. This may overflow and trap, but only if the rounded
        // result would have overflowed anyway.
        return (self + (powerOfTwo &- 1)) & (0 &- powerOfTwo)
    }
}

extension Dimensions {

    // Ensures width and height are even numbers
    internal func toEncodeSafeDimensions() -> Dimensions {
        Dimensions(width: Swift.max(encodeSafeSize, width.roundUp(toMultipleOf: 4)),
                   height: Swift.max(encodeSafeSize, height.roundUp(toMultipleOf: 4)))

    }

    internal static func * (a: Dimensions, b: Double) -> Dimensions {
        Dimensions(width: Int32((Double(a.width) * b).rounded()),
                   height: Int32((Double(a.height) * b).rounded()))
    }

    internal var isRenderSafe: Bool {
        width >= renderSafeSize && height >= renderSafeSize
    }
}

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
internal let renderSafeSize: Int32 = 8
internal let encodeSafeSize: Int32 = 16

extension RTCVideoCapturerDelegate {

    public typealias OnTargetDimensions = (Dimensions) -> Void

    /// capture a `CVPixelBuffer`, all other capture methods call this method internally.
    public func capturer(_ capturer: RTCVideoCapturer,
                         didCapture pixelBuffer: CVPixelBuffer,
                         timeStampNs: UInt64,
                         rotation: RTCVideoRotation = ._0,
                         scale: Double = 1.0,
                         onTargetDimensions: OnTargetDimensions? = nil) {

        // check if pixel format is supported by WebRTC
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard supportedPixelFormats.contains(where: { $0.uint32Value == pixelFormat }) else {
            // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            // kCVPixelFormatType_32BGRA
            // kCVPixelFormatType_32ARGB
            logger.log("Skipping capture for unsupported pixel format: \(pixelFormat.toString())", .warning,
                       type: type(of: self))
            return
        }

        let sourceDimensions = Dimensions(width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
                                          height: Int32(CVPixelBufferGetHeight(pixelBuffer)))

        guard sourceDimensions.width >= encodeSafeSize,
              sourceDimensions.height >= encodeSafeSize else {
            logger.log("Skipping capture for dimensions: \(sourceDimensions)", .warning,
                       type: type(of: self))
            return
        }

        // Dimensions which are adjusted to be safe with both VP8 and H264 encoders
        let targetDimensions = (sourceDimensions * scale).toEncodeSafeDimensions()

        // report back the computed target dimensions
        onTargetDimensions?(targetDimensions)

        if sourceDimensions != targetDimensions {
            logger.log("capturing with adapted dimensions: \(sourceDimensions) -> \(targetDimensions)",
                       type: type(of: self))
        }

        DispatchQueue.webRTC.sync {

            let rtcBuffer: RTCCVPixelBuffer

            if sourceDimensions == targetDimensions {
                // no adjustments required
                rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            } else {
                // apply adjustments
                rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer,
                                             adaptedWidth: targetDimensions.width,
                                             adaptedHeight: targetDimensions.height,
                                             cropWidth: sourceDimensions.width,
                                             cropHeight: sourceDimensions.height,
                                             cropX: 0,
                                             cropY: 0)
            }

            let rtcFrame = RTCVideoFrame(buffer: rtcBuffer,
                                         rotation: rotation,
                                         timeStampNs: Int64(timeStampNs))

            self.capturer(capturer, didCapture: rtcFrame)
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
            logger.log("Failed to capture, buffer is not ready", .warning, type: type(of: self))
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
            logger.log("Failed to capture, pixel buffer not found", .warning, type: type(of: self))
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
