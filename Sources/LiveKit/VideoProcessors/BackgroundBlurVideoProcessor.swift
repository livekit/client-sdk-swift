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

import CoreImage.CIFilterBuiltins
import Foundation
import Vision

@available(iOS 15.0, macOS 12.0, *)
@objc
public final class BackgroundBlurVideoProcessor: NSObject, VideoProcessor, Loggable {
    private let segmentationRequest = {
        let segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = .balanced
        return segmentationRequest
    }()

    private let requestHandler = VNSequenceRequestHandler()

    private let invertFilter = CIFilter.colorInvert()
    private let blurFilter = CIFilter.maskedVariableBlur()

    public func process(frame: VideoFrame) -> VideoFrame? {
        guard let pixelBuffer = frame.toCVPixelBuffer() else {
            return frame
        }

        do {
            try requestHandler.perform([segmentationRequest], on: pixelBuffer)
        } catch {
            return frame
        }

        guard let maskPixelBuffer = segmentationRequest.results?.first?.pixelBuffer else {
            return frame
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)

        let scaleX = ciImage.extent.width / maskImage.extent.width
        let scaleY = ciImage.extent.height / maskImage.extent.height

        invertFilter.inputImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let invertedMask = invertFilter.outputImage else {
            return frame
        }

        blurFilter.inputImage = ciImage
        blurFilter.mask = invertedMask
        blurFilter.radius = Float(0.005 * min(ciImage.extent.width, ciImage.extent.height))

        guard let outputImage = blurFilter.outputImage?.cropped(to: ciImage.extent) else {
            return frame
        }

        guard let outputPixelBuffer = outputImage.toPixelBuffer() else {
            return frame
        }

        let processedBuffer = CVPixelVideoBuffer(pixelBuffer: outputPixelBuffer)

        return VideoFrame(dimensions: frame.dimensions,
                          rotation: frame.rotation,
                          timeStampNs: frame.timeStampNs,
                          buffer: processedBuffer)
    }
}
