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
import CoreImage
import CoreMedia

extension CVPixelBuffer {

    public static func from(_ data: Data, width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer {
        data.withUnsafeBytes { buffer in
            var pixelBuffer: CVPixelBuffer!

            let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, nil, &pixelBuffer)
            guard result == kCVReturnSuccess else { fatalError() }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            var source = buffer.baseAddress!

            for plane in 0 ..< CVPixelBufferGetPlaneCount(pixelBuffer) {
                let dest      = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
                let height      = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let planeSize = height * bytesPerRow

                memcpy(dest, source, planeSize)
                source += planeSize
            }

            return pixelBuffer
        }
    }
}

extension CMSampleBuffer {

    public static func from(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {

        var sampleBuffer: CMSampleBuffer?

        var timimgInfo  = CMSampleTimingInfo()
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &formatDescription)

        let osStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription!,
            sampleTiming: &timimgInfo,
            sampleBufferOut: &sampleBuffer
        )

        // Print out errors
        if osStatus == kCMSampleBufferError_AllocationFailed {
            print("osStatus == kCMSampleBufferError_AllocationFailed")
        }
        if osStatus == kCMSampleBufferError_RequiredParameterMissing {
            print("osStatus == kCMSampleBufferError_RequiredParameterMissing")
        }
        if osStatus == kCMSampleBufferError_AlreadyHasDataBuffer {
            print("osStatus == kCMSampleBufferError_AlreadyHasDataBuffer")
        }
        if osStatus == kCMSampleBufferError_BufferNotReady {
            print("osStatus == kCMSampleBufferError_BufferNotReady")
        }
        if osStatus == kCMSampleBufferError_SampleIndexOutOfRange {
            print("osStatus == kCMSampleBufferError_SampleIndexOutOfRange")
        }
        if osStatus == kCMSampleBufferError_BufferHasNoSampleSizes {
            print("osStatus == kCMSampleBufferError_BufferHasNoSampleSizes")
        }
        if osStatus == kCMSampleBufferError_BufferHasNoSampleTimingInfo {
            print("osStatus == kCMSampleBufferError_BufferHasNoSampleTimingInfo")
        }
        if osStatus == kCMSampleBufferError_ArrayTooSmall {
            print("osStatus == kCMSampleBufferError_ArrayTooSmall")
        }
        if osStatus == kCMSampleBufferError_InvalidEntryCount {
            print("osStatus == kCMSampleBufferError_InvalidEntryCount")
        }
        if osStatus == kCMSampleBufferError_CannotSubdivide {
            print("osStatus == kCMSampleBufferError_CannotSubdivide")
        }
        if osStatus == kCMSampleBufferError_SampleTimingInfoInvalid {
            print("osStatus == kCMSampleBufferError_SampleTimingInfoInvalid")
        }
        if osStatus == kCMSampleBufferError_InvalidMediaTypeForOperation {
            print("osStatus == kCMSampleBufferError_InvalidMediaTypeForOperation")
        }
        if osStatus == kCMSampleBufferError_InvalidSampleData {
            print("osStatus == kCMSampleBufferError_InvalidSampleData")
        }
        if osStatus == kCMSampleBufferError_InvalidMediaFormat {
            print("osStatus == kCMSampleBufferError_InvalidMediaFormat")
        }
        if osStatus == kCMSampleBufferError_Invalidated {
            print("osStatus == kCMSampleBufferError_Invalidated")
        }
        if osStatus == kCMSampleBufferError_DataFailed {
            print("osStatus == kCMSampleBufferError_DataFailed")
        }
        if osStatus == kCMSampleBufferError_DataCanceled {
            print("osStatus == kCMSampleBufferError_DataCanceled")
        }

        guard let buffer = sampleBuffer else {
            print("Cannot create sample buffer")
            return nil
        }

        let attachments: CFArray! = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                       to: CFMutableDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
        let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        CFDictionarySetValue(dictionary, key, value)

        return buffer
    }
}

extension Data {

    public init(pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, [.readOnly]) }

        // Calculate sum of planes' size
        var totalSize = 0
        for plane in 0 ..< CVPixelBufferGetPlaneCount(pixelBuffer) {
            let height      = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let planeSize   = height * bytesPerRow
            totalSize += planeSize
        }

        guard let rawFrame = malloc(totalSize) else { fatalError() }
        var dest = rawFrame

        for plane in 0 ..< CVPixelBufferGetPlaneCount(pixelBuffer) {
            let source      = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
            let height      = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let planeSize   = height * bytesPerRow

            memcpy(dest, source, planeSize)
            dest += planeSize
        }

        self.init(bytesNoCopy: rawFrame, count: totalSize, deallocator: .free)
    }
}

extension OSType {
    // Get string representation of CVPixelFormatType
    func toString() -> String {
        let types = [
            kCVPixelFormatType_TwoComponent8: "kCVPixelFormatType_TwoComponent8",
            kCVPixelFormatType_TwoComponent32Float: "kCVPixelFormatType_TwoComponent32Float",
            kCVPixelFormatType_TwoComponent16Half: "kCVPixelFormatType_TwoComponent16Half",
            kCVPixelFormatType_TwoComponent16: "kCVPixelFormatType_TwoComponent16",
            kCVPixelFormatType_OneComponent8: "kCVPixelFormatType_OneComponent8",
            kCVPixelFormatType_OneComponent32Float: "kCVPixelFormatType_OneComponent32Float",
            kCVPixelFormatType_OneComponent16Half: "kCVPixelFormatType_OneComponent16Half",
            kCVPixelFormatType_OneComponent16: "kCVPixelFormatType_OneComponent16",
            kCVPixelFormatType_OneComponent12: "kCVPixelFormatType_OneComponent12",
            kCVPixelFormatType_OneComponent10: "kCVPixelFormatType_OneComponent10",
            kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange",
            kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange: "kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange",
            kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange: "kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange",
            kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange",
            kCVPixelFormatType_Lossy_32BGRA: "kCVPixelFormatType_Lossy_32BGRA",
            kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange",
            kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange: "kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange",
            kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange: "kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange",
            kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange",
            kCVPixelFormatType_Lossless_32BGRA: "kCVPixelFormatType_Lossless_32BGRA",
            kCVPixelFormatType_DisparityFloat32: "kCVPixelFormatType_DisparityFloat32",
            kCVPixelFormatType_DisparityFloat16: "kCVPixelFormatType_DisparityFloat16",
            kCVPixelFormatType_DepthFloat32: "kCVPixelFormatType_DepthFloat32",
            kCVPixelFormatType_DepthFloat16: "kCVPixelFormatType_DepthFloat16",
            kCVPixelFormatType_ARGB2101010LEPacked: "kCVPixelFormatType_ARGB2101010LEPacked",
            kCVPixelFormatType_8IndexedGray_WhiteIsZero: "kCVPixelFormatType_8IndexedGray_WhiteIsZero",
            kCVPixelFormatType_8Indexed: "kCVPixelFormatType_8Indexed",
            kCVPixelFormatType_64RGBALE: "kCVPixelFormatType_64RGBALE",
            kCVPixelFormatType_64RGBAHalf: "kCVPixelFormatType_64RGBAHalf",
            kCVPixelFormatType_64RGBA_DownscaledProResRAW: "kCVPixelFormatType_64RGBA_DownscaledProResRAW",
            kCVPixelFormatType_64ARGB: "kCVPixelFormatType_64ARGB",
            kCVPixelFormatType_4IndexedGray_WhiteIsZero: "kCVPixelFormatType_4IndexedGray_WhiteIsZero",
            kCVPixelFormatType_4Indexed: "kCVPixelFormatType_4Indexed",
            kCVPixelFormatType_48RGB: "kCVPixelFormatType_48RGB",
            kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: "kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange",
            kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: "kCVPixelFormatType_444YpCbCr8BiPlanarFullRange",
            kCVPixelFormatType_444YpCbCr8: "kCVPixelFormatType_444YpCbCr8",
            kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar: "kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar",
            kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange: "kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange",
            kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: "kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange",
            kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: "kCVPixelFormatType_444YpCbCr10BiPlanarFullRange",
            kCVPixelFormatType_444YpCbCr10: "kCVPixelFormatType_444YpCbCr10",
            kCVPixelFormatType_4444YpCbCrA8R: "kCVPixelFormatType_4444YpCbCrA8R",
            kCVPixelFormatType_4444YpCbCrA8: "kCVPixelFormatType_4444YpCbCrA8",
            kCVPixelFormatType_4444AYpCbCr8: "kCVPixelFormatType_4444AYpCbCr8",
            kCVPixelFormatType_4444AYpCbCr16: "kCVPixelFormatType_4444AYpCbCr16",
            kCVPixelFormatType_422YpCbCr8FullRange: "kCVPixelFormatType_422YpCbCr8FullRange",
            kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: "kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange",
            kCVPixelFormatType_422YpCbCr8BiPlanarFullRange: "kCVPixelFormatType_422YpCbCr8BiPlanarFullRange",
            kCVPixelFormatType_422YpCbCr8_yuvs: "kCVPixelFormatType_422YpCbCr8_yuvs",
            kCVPixelFormatType_422YpCbCr8: "kCVPixelFormatType_422YpCbCr8",
            kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange: "kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange",
            kCVPixelFormatType_422YpCbCr16: "kCVPixelFormatType_422YpCbCr16",
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: "kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange",
            kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: "kCVPixelFormatType_422YpCbCr10BiPlanarFullRange",
            kCVPixelFormatType_422YpCbCr10: "kCVPixelFormatType_422YpCbCr10",
            kCVPixelFormatType_422YpCbCr_4A_8BiPlanar: "kCVPixelFormatType_422YpCbCr_4A_8BiPlanar",
            kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar: "kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar",
            kCVPixelFormatType_420YpCbCr8PlanarFullRange: "kCVPixelFormatType_420YpCbCr8PlanarFullRange",
            kCVPixelFormatType_420YpCbCr8Planar: "kCVPixelFormatType_420YpCbCr8Planar",
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: "kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange",
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: "kCVPixelFormatType_420YpCbCr8BiPlanarFullRange",
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: "kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange",
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: "kCVPixelFormatType_420YpCbCr10BiPlanarFullRange",
            kCVPixelFormatType_40ARGBLEWideGamutPremultiplied: "kCVPixelFormatType_40ARGBLEWideGamutPremultiplied",
            kCVPixelFormatType_40ARGBLEWideGamut: "kCVPixelFormatType_40ARGBLEWideGamut",
            kCVPixelFormatType_32RGBA: "kCVPixelFormatType_32RGBA",
            kCVPixelFormatType_32BGRA: "kCVPixelFormatType_32BGRA",
            kCVPixelFormatType_32ARGB: "kCVPixelFormatType_32ARGB",
            kCVPixelFormatType_32AlphaGray: "kCVPixelFormatType_32AlphaGray",
            kCVPixelFormatType_32ABGR: "kCVPixelFormatType_32ABGR",
            kCVPixelFormatType_30RGBLEPackedWideGamut: "kCVPixelFormatType_30RGBLEPackedWideGamut",
            kCVPixelFormatType_30RGB: "kCVPixelFormatType_30RGB",
            kCVPixelFormatType_2IndexedGray_WhiteIsZero: "kCVPixelFormatType_2IndexedGray_WhiteIsZero",
            kCVPixelFormatType_2Indexed: "kCVPixelFormatType_2Indexed",
            kCVPixelFormatType_24RGB: "kCVPixelFormatType_24RGB",
            kCVPixelFormatType_24BGR: "kCVPixelFormatType_24BGR",
            kCVPixelFormatType_1Monochrome: "kCVPixelFormatType_1Monochrome",
            kCVPixelFormatType_1IndexedGray_WhiteIsZero: "kCVPixelFormatType_1IndexedGray_WhiteIsZero",
            kCVPixelFormatType_16VersatileBayer: "kCVPixelFormatType_16VersatileBayer",
            kCVPixelFormatType_16LE565: "kCVPixelFormatType_16LE565",
            kCVPixelFormatType_16LE5551: "kCVPixelFormatType_16LE5551",
            kCVPixelFormatType_16LE555: "kCVPixelFormatType_16LE555",
            kCVPixelFormatType_16Gray: "kCVPixelFormatType_16Gray",
            kCVPixelFormatType_16BE565: "kCVPixelFormatType_16BE565",
            kCVPixelFormatType_16BE555: "kCVPixelFormatType_16BE555",
            kCVPixelFormatType_14Bayer_RGGB: "kCVPixelFormatType_14Bayer_RGGB",
            kCVPixelFormatType_14Bayer_GRBG: "kCVPixelFormatType_14Bayer_GRBG",
            kCVPixelFormatType_14Bayer_GBRG: "kCVPixelFormatType_14Bayer_GBRG",
            kCVPixelFormatType_14Bayer_BGGR: "kCVPixelFormatType_14Bayer_BGGR",
            kCVPixelFormatType_128RGBAFloat: "kCVPixelFormatType_128RGBAFloat"
        ]

        return types[self] ?? "Unknown type"
    }
}
