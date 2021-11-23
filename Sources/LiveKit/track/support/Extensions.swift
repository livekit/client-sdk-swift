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
