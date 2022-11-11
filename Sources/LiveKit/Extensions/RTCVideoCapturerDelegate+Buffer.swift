/*
 * Copyright 2022 LiveKit
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

import Foundation
import WebRTC

#if canImport(ReplayKit)
import ReplayKit
#endif

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
        Dimensions(width: Swift.max(Self.encodeSafeSize, width.roundUp(toMultipleOf: 2)),
                   height: Swift.max(Self.encodeSafeSize, height.roundUp(toMultipleOf: 2)))

    }

    internal static func * (a: Dimensions, b: Double) -> Dimensions {
        Dimensions(width: Int32((Double(a.width) * b).rounded()),
                   height: Int32((Double(a.height) * b).rounded()))
    }

    internal var isRenderSafe: Bool {
        width >= Self.renderSafeSize && height >= Self.renderSafeSize
    }

    internal var isEncodeSafe: Bool {
        width >= Self.encodeSafeSize && height >= Self.encodeSafeSize
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

extension RTCVideoCapturerDelegate {

    public typealias OnResolveSourceDimensions = (Dimensions) -> Void

    /// capture a `CVPixelBuffer`, all other capture methods call this method internally.
    public func capturer(_ capturer: RTCVideoCapturer,
                         didCapture pixelBuffer: CVPixelBuffer,
                         timeStampNs: Int64 = VideoCapturer.createTimeStampNs(),
                         rotation: RTCVideoRotation = ._0,
                         onResolveSourceDimensions: OnResolveSourceDimensions? = nil) {

        // check if pixel format is supported by WebRTC
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard VideoCapturer.supportedPixelFormats.contains(where: { $0.uint32Value == pixelFormat }) else {
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

        guard sourceDimensions.isEncodeSafe else {
            logger.log("Skipping capture for dimensions: \(sourceDimensions)", .warning,
                       type: type(of: self))
            return
        }

        onResolveSourceDimensions?(sourceDimensions)

        DispatchQueue.webRTC.sync {

            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let rtcFrame = RTCVideoFrame(buffer: rtcBuffer,
                                         rotation: rotation,
                                         timeStampNs: timeStampNs)

            self.capturer(capturer, didCapture: rtcFrame)
        }
    }

    /// capture a `CMSampleBuffer`
    public func capturer(_ capturer: RTCVideoCapturer,
                         didCapture sampleBuffer: CMSampleBuffer,
                         onResolveSourceDimensions: OnResolveSourceDimensions? = nil) {

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

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        self.capturer(capturer,
                      didCapture: pixelBuffer,
                      timeStampNs: timeStampNs,
                      rotation: rotation ?? ._0,
                      onResolveSourceDimensions: onResolveSourceDimensions)
    }
}

extension CVPixelBuffer {

    func toDimensions() -> Dimensions {
        Dimensions(width: Int32(CVPixelBufferGetWidth(self)),
                   height: Int32(CVPixelBufferGetHeight(self)))
    }
}
