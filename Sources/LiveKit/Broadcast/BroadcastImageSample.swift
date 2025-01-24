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
import ReplayKit

struct BroadcastImageSample: Codable {
    let width: Int
    let height: Int
    let orientation: CGImagePropertyOrientation
    let jpegData: Data
}

extension BroadcastImageSample {
    
    enum ConversionError: Swift.Error {
        case notImageBuffer
        case imageCodecFailure
    }
    
    init(_ sampleBuffer: CMSampleBuffer, quality: CGFloat = 1.0) throws(ConversionError) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw .notImageBuffer
        }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        guard let jpegData = BroadcastImageCodec.jpegData(from: imageBuffer, quality: quality) else {
            throw .imageCodecFailure
        }
        self.init(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer),
            orientation: sampleBuffer.replayKitOrientation ?? .up,
            jpegData: jpegData
        )
    }
    
    func toImageBuffer() throws(ConversionError) -> CVImageBuffer {
        guard let imageBuffer = BroadcastImageCodec.imageBuffer(from: jpegData, width: width, height: height) else {
            throw .imageCodecFailure
        }
        return imageBuffer
    }
}

extension CGImagePropertyOrientation: Codable {}

extension CMSampleBuffer {
    /// Gets the image orientation attached by ReplayKit.
    var replayKitOrientation: CGImagePropertyOrientation? {
        guard let rawOrientation = CMGetAttachment(
            self,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        )?.uint32Value else { return nil }
        return CGImagePropertyOrientation(rawValue: rawOrientation)
    }
}

struct BroadcastImageCodec {
    /// Encode the given image buffer to JPEG data.
    ///
    /// - Warning: The given image buffer must already have its base address locked.
    ///
    static func jpegData(from imageBuffer: CVImageBuffer, quality: CGFloat) -> Data? {
        let image = CIImage(cvPixelBuffer: imageBuffer)
        guard #available(iOS 17.0, *) else {
            // Workaround for "unsupported file format 'public.heic'"
            guard let cgImage = Self.imageContext.createCGImage(image, from: image.extent) else {
                return nil
            }

            let data = NSMutableData()
            guard let imageDestination = CGImageDestinationCreateWithData(data, AVFileType.jpg as CFString, 1, nil) else {
                return nil
            }

            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(imageDestination, cgImage, options as CFDictionary)

            guard CGImageDestinationFinalize(imageDestination) else {
                return nil
            }
            return data as Data
        }
        return Self.imageContext.jpegRepresentation(
            of: image,
            colorSpace: Self.colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
    
    /// Decodes the given JPEG data as an image buffer.
    static func imageBuffer(from jpegData: Data, width: Int, height: Int) -> CVImageBuffer? {
        var imageBuffer: CVImageBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &imageBuffer)
        guard status == kCVReturnSuccess, let imageBuffer else {
            logger.warning("CVPixelBufferCreate failed")
            return nil
        }
        
        CVPixelBufferLockBaseAddress(imageBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, []) }
        
        guard let image = CIImage(data: jpegData) else {
            logger.debug("Failed to create CIImage")
            return nil
        }
        Self.imageContext.render(image, to: imageBuffer)
        return imageBuffer
    }
    
    // Initializing a CIContext object is costly, so we use a singleton instead
    private static let imageContext = CIContext(options: nil)
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
}
