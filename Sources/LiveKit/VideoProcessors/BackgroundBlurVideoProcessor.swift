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
@preconcurrency import CoreVideo
import Foundation
import Metal
import MetalKit
import Vision

@available(iOS 15.0, macOS 12.0, *)
@objc
public final class BackgroundBlurVideoProcessor: NSObject, VideoProcessor, Loggable {
    private let segmentationRequest = {
        let segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = .balanced
        // Set revision to 1 for better performance on supported devices (newer devices)
//        segmentationRequest.revision = 1
        return segmentationRequest
    }()

    private let requestHandler = VNSequenceRequestHandler()

    // Dedicated processing queue for Vision requests
    private let visionQueue = DispatchQueue(label: "io.livekit.backgroundblur.vision")

    // Create a Metal-accelerated CIContext
    private let ciContext: CIContext = {
        // Use default Metal device if available
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                //                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
//                .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
                .useSoftwareRenderer: false,
                .priorityRequestLow: false,
            ])
        }
        return CIContext()
    }()

    private let invertFilter = CIFilter.colorInvert()
    private let blurFilter = CIFilter.maskedVariableBlur()

    // Cache for transformed mask
    private var lastInputDimensions: CGSize?
    private var lastMaskDimensions: CGSize?
    private var scaleTransform: CGAffineTransform?

    // Cached output pixel buffer for reuse
    private var outputPixelBuffer: CVPixelBuffer?
    private var outputBufferDimensions: CGSize?

    // Cache the last mask result for frame dropping
    private var lastMaskImage: CIImage?
    private var lastMaskTimestamp: Int64 = 0

    // Track processing state
    private let processingLock = NSLock()
    private var isProcessingVision = false

    // Frame skipping for performance
    private var frameCount = 0
    private let visionFrameInterval = 3 // Process vision every N frames

    public func process(frame: VideoFrame) -> VideoFrame? {
        guard let pixelBuffer = frame.toCVPixelBuffer() else {
            return frame
        }

        frameCount += 1

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        var maskImage: CIImage?

        // Only run vision request every few frames to improve performance
        if frameCount % visionFrameInterval == 0 {
            // Check if we're already processing - if so, use cached mask
            if !isProcessingVision {
                processingLock.lock()
                isProcessingVision = true
                processingLock.unlock()

                // Run vision request asynchronously
                visionQueue.async { [weak self] in
                    guard let self else { return }

                    profile("bpreq") {
                        try? self.requestHandler.perform([self.segmentationRequest], on: pixelBuffer)
                    }

                    // Process mask result
                    if let maskPixelBuffer = self.segmentationRequest.results?.first?.pixelBuffer {
                        let newMaskImage = CIImage(cvPixelBuffer: maskPixelBuffer)

                        self.processingLock.lock()
                        self.lastMaskImage = newMaskImage
                        self.lastMaskTimestamp = frame.timeStampNs
                        self.isProcessingVision = false
                        self.processingLock.unlock()
                    } else {
                        self.processingLock.lock()
                        self.isProcessingVision = false
                        self.processingLock.unlock()
                    }
                }
            }
        }

        // Use the last available mask
        processingLock.lock()
        maskImage = lastMaskImage
        processingLock.unlock()

        // If no mask is available yet, return original frame
        guard let maskImage else {
            return frame
        }

        // Calculate scale transform only when dimensions change
        let inputDimensions = ciImage.extent.size
        let maskDimensions = maskImage.extent.size

        if lastInputDimensions != inputDimensions || lastMaskDimensions != maskDimensions {
            let scaleX = inputDimensions.width / maskDimensions.width
            let scaleY = inputDimensions.height / maskDimensions.height
            scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)

            // Update cached dimensions
            lastInputDimensions = inputDimensions
            lastMaskDimensions = maskDimensions

            // Recreate output buffer if dimensions changed
            outputBufferDimensions = nil
        }

        return profile("bpfilter") {
            // Use cached transform
            invertFilter.inputImage = maskImage.transformed(by: scaleTransform!)

            guard let invertedMask = invertFilter.outputImage else {
                return frame
            }

            blurFilter.inputImage = ciImage
            blurFilter.mask = invertedMask
            blurFilter.radius = Float(0.005 * min(ciImage.extent.width, ciImage.extent.height))

            guard let outputImage = blurFilter.outputImage?.cropped(to: ciImage.extent) else {
                return frame
            }

            // Reuse pixel buffer if possible
            if outputBufferDimensions != inputDimensions {
                outputPixelBuffer = createOutputBuffer(width: Int(inputDimensions.width),
                                                       height: Int(inputDimensions.height))
                outputBufferDimensions = inputDimensions
            }

            guard let outputBuffer = outputPixelBuffer else {
                return frame
            }

            // Render directly to output buffer using Metal-accelerated CIContext
            ciContext.render(outputImage, to: outputBuffer)

            let processedBuffer = CVPixelVideoBuffer(pixelBuffer: outputBuffer)

            return VideoFrame(dimensions: frame.dimensions,
                              rotation: frame.rotation,
                              timeStampNs: frame.timeStampNs,
                              buffer: processedBuffer)
        }
    }

    private func createOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes = [
            //            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue as Any,
//            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue as Any,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue as Any,
//            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes,
                                         &pixelBuffer)

        guard status == kCVReturnSuccess else {
            return nil
        }

        return pixelBuffer
    }
}

import QuartzCore

func profile<T>(_: String, _ block: () -> T) -> T {
//    let start = CACurrentMediaTime()
//    let r = block()
//    let end = CACurrentMediaTime()
//    print("\(label) Time taken: \(end - start) seconds")
//    return r

    block()
}
