import WebRTC
import ReplayKit

extension CVPixelBuffer {

    public func toRTCVideoFrame(timeStampNs: Int64) -> RTCVideoFrame {
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

extension CGImage {

    /// Convenience method to convert ``CGImage`` to ``CVPixelBuffer``
    public func toPixelBuffer(pixelFormatType: OSType = kCVPixelFormatType_32ARGB,
                              colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB(),
                              alphaInfo: CGImageAlphaInfo = .noneSkipFirst) -> CVPixelBuffer? {

        var maybePixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         pixelFormatType,
                                         attrs as CFDictionary,
                                         &maybePixelBuffer)

        guard status == kCVReturnSuccess, let pixelBuffer = maybePixelBuffer else {
            return nil
        }

        let flags = CVPixelBufferLockFlags(rawValue: 0)
        guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(pixelBuffer, flags) else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, flags) }

        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: colorSpace,
                                      bitmapInfo: alphaInfo.rawValue)
        else {
            return nil
        }

        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}

#if os(iOS)
@available(iOS 12, *)
extension RPSystemBroadcastPickerView {

    /// Convenience function to show broadcast extension picker
    public static func show(for preferredExtension: String? = nil,
                            showsMicrophoneButton: Bool = true) {
        let view = RPSystemBroadcastPickerView()
        view.preferredExtension = preferredExtension
        view.showsMicrophoneButton = showsMicrophoneButton
        let selector = NSSelectorFromString("buttonPressed:")
        if view.responds(to: selector) {
            view.perform(selector, with: nil)
        }
    }
}
#endif
