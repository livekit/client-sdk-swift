/*
 * Copyright 2024 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import CoreImage
import Foundation

#if canImport(ReplayKit)
import ReplayKit
#endif

public extension CIImage {
    /// Convenience method to convert ``CIImage`` to ``CVPixelBuffer``
    /// since ``CIImage/pixelBuffer`` is not always available.
    func toPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        // get current size
        let size: CGSize = extent.size

        // default options
        let options = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ] as [String: Any]

        let status: CVReturn = CVPixelBufferCreate(kCFAllocatorDefault,
                                                   Int(size.width),
                                                   Int(size.height),
                                                   kCVPixelFormatType_32BGRA,
                                                   options as CFDictionary,
                                                   &pixelBuffer)

        let ciContext = CIContext()

        if let pixelBuffer, status == kCVReturnSuccess {
            ciContext.render(self, to: pixelBuffer)
        }

        return pixelBuffer
    }
}

public extension CGImage {
    /// Convenience method to convert ``CGImage`` to ``CVPixelBuffer``
    func toPixelBuffer(pixelFormatType: OSType = kCVPixelFormatType_32ARGB,
                       colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB(),
                       alphaInfo: CGImageAlphaInfo = .noneSkipFirst) -> CVPixelBuffer?
    {
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
public extension RPSystemBroadcastPickerView {
    /// Convenience function to show broadcast extension picker
    static func show(for preferredExtension: String? = nil,
                     showsMicrophoneButton: Bool = true)
    {
        if !Thread.current.isMainThread {
            logger.log("Must be called on main thread", .error, type: RPSystemBroadcastPickerView.self)
        }

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
