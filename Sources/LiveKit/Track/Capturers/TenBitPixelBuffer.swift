/*
 * Copyright 2026 LiveKit
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

internal import LiveKitWebRTC
import CoreVideo

/// A 10-bit 4:2:0 bi-planar frame (``VideoCapturer/tenBitPixelFormats``) that WebRTC's own encoders and scaling can read too.
///
/// A custom encoder set with ``LiveKitSDK/set(videoEncoderFactory:)`` takes ``pixelBuffer`` as it is. WebRTC's own encoders
/// and its scaling read a frame through `toI420()` and `cropAndScaleTo(_:withTempBuffer:)`, which `LKRTCCVPixelBuffer`
/// implements only for ``VideoCapturer/supportedPixelFormats``: for any other format it returns planes it never wrote. Here
/// they read an 8-bit NV12 copy of the frame instead, each sample's high byte.
final class TenBitPixelBuffer: LKRTCCVPixelBuffer {
    override func cropAndScale(with offsetX: Int32,
                               offsetY: Int32,
                               cropWidth: Int32,
                               cropHeight: Int32,
                               scaleWidth: Int32,
                               scaleHeight: Int32) -> any LKRTCVideoFrameBuffer
    {
        TenBitPixelBuffer(pixelBuffer: pixelBuffer,
                          adaptedWidth: scaleWidth,
                          adaptedHeight: scaleHeight,
                          cropWidth: cropWidth * self.cropWidth / width,
                          cropHeight: cropHeight * self.cropHeight / height,
                          cropX: cropX + offsetX * self.cropWidth / width,
                          cropY: cropY + offsetY * self.cropHeight / height)
    }

    override func toI420() -> any LKRTCI420BufferProtocol {
        eightBit()?.toI420() ?? Self.black(width: width, height: height)
    }

    override func bufferSizeForCroppingAndScaling(toWidth width: Int32, height: Int32) -> Int32 {
        ((cropWidth + 1) / 2) * ((cropHeight + 1) / 2) * 2 + ((width + 1) / 2) * ((height + 1) / 2) * 2
    }

    override func cropAndScale(to outputPixelBuffer: CVPixelBuffer, withTempBuffer tmpBuffer: UnsafeMutablePointer<UInt8>?) -> Bool {
        eightBit()?.cropAndScale(to: outputPixelBuffer, withTempBuffer: tmpBuffer) ?? false
    }

    /// The frame with its crop and size over an 8-bit copy of its pixels.
    private func eightBit() -> LKRTCCVPixelBuffer? {
        guard let copy = Self.eightBitCopy(of: pixelBuffer) else { return nil }
        return LKRTCCVPixelBuffer(pixelBuffer: copy,
                                  adaptedWidth: width,
                                  adaptedHeight: height,
                                  cropWidth: cropWidth,
                                  cropHeight: cropHeight,
                                  cropX: cropX,
                                  cropY: cropY)
    }

    /// An NV12 copy of a 10-bit bi-planar buffer in the same range: a sample's 10 bits sit in the top of its 16, so its
    /// high byte is the 8-bit value (video range 64...940 becomes 16...235).
    static func eightBitCopy(of source: CVPixelBuffer) -> CVPixelBuffer? {
        let fullRange = CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                                  format, attributes, &made) == kCVReturnSuccess, let copy = made
        else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        for plane in 0 ..< 2 {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { return nil }
            // Luma has one sample a pixel, the chroma plane a Cb and a Cr.
            let samples = CVPixelBufferGetWidthOfPlane(source, plane) * (plane == 0 ? 1 : 2)
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
            for row in 0 ..< CVPixelBufferGetHeightOfPlane(source, plane) {
                let line = (from + row * fromStride).assumingMemoryBound(to: UInt16.self)
                let out = (to + row * toStride).assumingMemoryBound(to: UInt8.self)
                for sample in 0 ..< samples {
                    out[sample] = UInt8(truncatingIfNeeded: line[sample] >> 8)
                }
            }
        }
        return copy
    }

    /// A black I420 frame, in case the copy cannot be made: never planes left unwritten.
    private static func black(width: Int32, height: Int32) -> LKRTCMutableI420Buffer {
        let buffer = LKRTCMutableI420Buffer(width: width, height: height)
        memset(buffer.mutableDataY, 16, Int(buffer.strideY) * Int(height))
        memset(buffer.mutableDataU, 128, Int(buffer.strideU) * Int(buffer.chromaHeight))
        memset(buffer.mutableDataV, 128, Int(buffer.strideV) * Int(buffer.chromaHeight))
        return buffer
    }
}
