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
import CoreVideo.CVBuffer
import Vision

#if LK_SIGNPOSTS
import os.signpost
#endif

/// A ``VideoProcessor`` that blurs the background of a video stream.
///
/// This processor uses Vision framework to generate a mask of the person in the video stream,
/// downscales the background, applies a blur, and then blends it back with the foreground.
///
/// - Important: This class is not thread safe and will be called on a dedicated serial `processingQueue`.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, visionOS 1.0, *)
@objc
public final class BackgroundBlurVideoProcessor: NSObject, @unchecked Sendable, VideoProcessor, Loggable {
    #if LK_SIGNPOSTS
    private let signpostLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "", category: "BackgroundBlur")
    #endif

    // MARK: Parameters

    private let downscaleFactor: CGFloat = 2 // Downscale before blurring, upscale before blending
    private let blurRadius: Float = 3 // Keep the kernel size small O(n^2)
    private let relativeSize: CGFloat = 1080 // Blur effect optimized for HD, extrapolate for other video sizes

    // Skip segmentation every N frames for slower devices
    private var frameCount = 0
    #if os(macOS)
    private let segmentationFrameInterval = 1
    #else
    private let segmentationFrameInterval = 3
    #endif

    // MARK: Vision

    private let segmentationRequest = VNGeneratePersonSegmentationRequest()
    private let segmentationRequestHandler = VNSequenceRequestHandler()
    // Matches Vision internal QoS to avoid priority inversion
    private let segmentationQueue = DispatchQueue(label: "io.livekit.backgroundblur.segmentation", qos: .default, autoreleaseFrequency: .workItem)

    // MARK: CoreImage

    private let ciContext: CIContext = .metal()

    private let blurFilter = CIFilter.gaussianBlur()
    private let blendFilter = CIFilter.blendWithMask()

    // MARK: Cache

    private var cachedMaskImage: CIImage?
    private var cachedPixelBuffer: CVPixelBuffer?
    private var cachedPixelBufferSize: CGSize?

    // MARK: Init

    /// Initialize the background blur video processor.
    /// - Parameter highQuality: If true, use more detailed segmentation, but at the cost of performance.
    public init(highQuality: Bool = true) {
        segmentationRequest.qualityLevel = highQuality ? .balanced : .fast
    }

    // MARK: VideoProcessor

    public func process(frame: VideoFrame) -> VideoFrame? {
        frameCount += 1

        guard let inputBuffer = frame.toCVPixelBuffer() else { return frame }
        let cropRect = CGRect(x: .zero, y: .zero, width: Int(frame.dimensions.width), height: Int(frame.dimensions.height))

        let inputImage = CIImage(cvPixelBuffer: inputBuffer).croppedAndScaled(to: cropRect)
        let inputDimensions = inputImage.extent.size

        // Mask

        cacheMask(inputBuffer: inputBuffer, inputDimensions: inputDimensions)
        guard let maskImage = cachedMaskImage else { return frame }

        // Blur

        let downscaleTransform = getDownscaleTransform(relativeTo: inputDimensions)
        let downscaledImage = inputImage.transformed(by: downscaleTransform, highQualityDownsample: false)

        blurFilter.inputImage = downscaledImage.clampedToExtent()
        blurFilter.radius = blurRadius

        guard let blurredImage = blurFilter.outputImage else { return frame }
        let upscaledBlurredImage = blurredImage.transformed(by: downscaleTransform.inverted(), highQualityDownsample: false)

        // Blend

        blendFilter.inputImage = inputImage
        blendFilter.backgroundImage = upscaledBlurredImage
        blendFilter.maskImage = maskImage

        guard let outputImage = blendFilter.outputImage else { return frame }

        // Render

        guard let outputBuffer = getOutputBuffer(of: inputDimensions) else { return frame }

        #if LK_SIGNPOSTS
        os_signpost(.begin, log: signpostLog, name: "filter+render")
        #endif
        ciContext.render(outputImage, to: outputBuffer)
        #if LK_SIGNPOSTS
        os_signpost(.end, log: signpostLog, name: "filter+render")
        #endif

        return VideoFrame(dimensions: frame.dimensions,
                          rotation: frame.rotation,
                          timeStampNs: frame.timeStampNs,
                          buffer: CVPixelVideoBuffer(pixelBuffer: outputBuffer))
    }

    private func cacheMask(inputBuffer: CVPixelBuffer, inputDimensions: CGSize) {
        guard frameCount % segmentationFrameInterval == 0 else { return }

        segmentationQueue.async {
            #if LK_SIGNPOSTS
            os_signpost(.begin, log: self.signpostLog, name: #function)
            defer {
                os_signpost(.end, log: self.signpostLog, name: #function)
            }
            #endif
            try? self.segmentationRequestHandler.perform([self.segmentationRequest], on: inputBuffer)

            guard let maskPixelBuffer = self.segmentationRequest.results?.first?.pixelBuffer else { return }
            let maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)
            let maskDimensions = maskImage.extent.size

            // Scale the mask back to input dimensions
            let scaleX = inputDimensions.width / maskDimensions.width
            let scaleY = inputDimensions.height / maskDimensions.height
            let scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)

            self.cachedMaskImage = maskImage.transformed(by: scaleTransform)
        }
    }

    private func getDownscaleTransform(relativeTo size: CGSize) -> CGAffineTransform {
        let sizeFactor = min(size.width, size.height) / relativeSize

        // Do not upscale smaller inputs
        let scale = 1 / (downscaleFactor * sizeFactor)
        return scale < 1 ? CGAffineTransform(scaleX: scale, y: scale) : .identity
    }

    private func getOutputBuffer(of size: CGSize) -> CVPixelBuffer? {
        if cachedPixelBufferSize != size {
            cachedPixelBuffer = .metal(width: Int(size.width), height: Int(size.height))
            cachedPixelBufferSize = size
        }
        return cachedPixelBuffer
    }
}

extension CVPixelBuffer: @unchecked Swift.Sendable {}
