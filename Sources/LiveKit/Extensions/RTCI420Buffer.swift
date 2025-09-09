/*
 * Copyright 2025 LiveKit
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

internal import LiveKitWebRTC

extension LKRTCI420Buffer {
    func toPixelBuffer() -> CVPixelBuffer? {
        // default options
        let options = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ] as [String: Any]

        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(width),
                                         Int(height),
                                         kCVPixelFormatType_32BGRA,
                                         options as CFDictionary,
                                         &outputPixelBuffer)

        guard status == kCVReturnSuccess, let outputPixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(outputPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        let pixelFormat = CVPixelBufferGetPixelFormatType(outputPixelBuffer)

        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        {
            // NV12
            let dstY = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0)
            let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0)
            let dstUV = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1)
            let dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1)

            LKRTCYUVHelper.i420(toNV12: dataY,
                                srcStrideY: strideY,
                                srcU: dataU,
                                srcStrideU: strideU,
                                srcV: dataV,
                                srcStrideV: strideV,
                                dstY: dstY,
                                dstStrideY: Int32(dstYStride),
                                dstUV: dstUV,
                                dstStrideUV: Int32(dstUVStride),
                                width: width,
                                height: height)

        } else {
            let dst = CVPixelBufferGetBaseAddress(outputPixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer)

            if pixelFormat == kCVPixelFormatType_32BGRA {
                LKRTCYUVHelper.i420(toARGB: dataY,
                                    srcStrideY: strideY,
                                    srcU: dataU,
                                    srcStrideU: strideU,
                                    srcV: dataV,
                                    srcStrideV: strideV,
                                    dstARGB: dst,
                                    dstStrideARGB: Int32(bytesPerRow),
                                    width: width,
                                    height: height)
            } else if pixelFormat == kCVPixelFormatType_32ARGB {
                LKRTCYUVHelper.i420(toBGRA: dataY,
                                    srcStrideY: strideY,
                                    srcU: dataU,
                                    srcStrideU: strideU,
                                    srcV: dataV,
                                    srcStrideV: strideV,
                                    dstBGRA: dst,
                                    dstStrideBGRA: Int32(bytesPerRow),
                                    width: width,
                                    height: height)
            }
        }

        CVPixelBufferUnlockBaseAddress(outputPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        return outputPixelBuffer
    }
}
