import WebRTC

extension CVPixelBuffer {

    func toRTCVideoFrame(timeStampNs: Int64) -> RTCVideoFrame {
        let pixelBuffer = RTCCVPixelBuffer(pixelBuffer: self)
        return RTCVideoFrame(buffer: pixelBuffer,
                             rotation: ._0,
                             timeStampNs: timeStampNs)
    }
}

extension CIImage {

    /// Convenience method to convert ``CIImage`` to ``CVPixelBuffer``
    /// since ``CIImage/pixelBuffer`` is not always available.
    public func toPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        // get current size
        let size: CGSize = extent.size

        // default options
        let options = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as [String: Any]

        let status: CVReturn = CVPixelBufferCreate(kCFAllocatorDefault,
                                                   Int(size.width),
                                                   Int(size.height),
                                                   kCVPixelFormatType_32BGRA,
                                                   options as CFDictionary,
                                                   &pixelBuffer)

        let ciContext = CIContext()

        if status == kCVReturnSuccess && pixelBuffer != nil {
            ciContext.render(self, to: pixelBuffer!)
        }

        return pixelBuffer
    }
}
