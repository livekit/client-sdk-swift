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
/// This processor uses Vision to generate a mask of the person in the video stream and then applies a blur to the background.
///
@available(iOS 15.0, macOS 12.0, tvOS 15.0, visionOS 1.0, *)
@objc
public final class BackgroundBlurVideoProcessor: NSObject, @unchecked Sendable, VideoProcessor, Loggable {
    #if LK_SIGNPOSTS
    private let signpostLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "", category: "BackgroundBlur")
    #endif

    // MARK: Parameters

    public let intensity: CGFloat

    // MARK: Vision

    private let segmentationRequest = {
        let segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = .balanced
        return segmentationRequest
    }()

    private let segmentationRequestHandler = VNSequenceRequestHandler()
    // Matches Vision internal QoS to avoid priority inversion
    private let segmentationQueue = DispatchQueue(label: "io.livekit.backgroundblur.segmentation", qos: .default)

    // MARK: Performance

    private var frameCount = 0
    #if os(macOS)
    private let segmentationFrameInterval = 1
    #else
    private let segmentationFrameInterval = 3
    #endif

    // MARK: CoreImage

    private let ciContext: CIContext = .metal()

    private let invertFilter = CIFilter.colorInvert()
    private let blurFilter = CIFilter.maskedVariableBlur()

    // MARK: Cache

    private var cachedMaskImage: CIImage?

    private var cachedPixelBuffer: CVPixelBuffer?
    private var cachedPixelBufferSize: CGSize?

    // MARK: Init

    /// - Parameters:
    ///   - intensity: The intensity of the blur effect, relative to the smallest dimension of the video frame.
    public init(intensity: CGFloat = 0.01) {
        self.intensity = intensity
    }

    // MARK: VideoProcessor

    public func process(frame: VideoFrame) -> VideoFrame? {
        #if LK_SIGNPOSTS
        os_signpost(.begin, log: signpostLog, name: #function)
        defer {
            os_signpost(.end, log: signpostLog, name: #function)
        }
        #endif

        frameCount += 1

        guard let inputBuffer = frame.toCVPixelBuffer() else { return frame }

        let inputImage = CIImage(cvPixelBuffer: inputBuffer)
        let inputDimensions = inputImage.extent.size

        cacheMask(inputBuffer: inputBuffer, inputDimensions: inputDimensions)

        blurFilter.inputImage = inputImage
        blurFilter.mask = cachedMaskImage
        blurFilter.radius = Float(intensity * min(inputDimensions.width, inputDimensions.height))

        guard let outputImage = blurFilter.outputImage?.cropped(to: inputImage.extent) else { return frame }
        guard let outputBuffer = getOutputBuffer(of: inputDimensions) else { return frame }

        ciContext.render(outputImage, to: outputBuffer)

        return VideoFrame(dimensions: frame.dimensions,
                          rotation: frame.rotation,
                          timeStampNs: frame.timeStampNs,
                          buffer: CVPixelVideoBuffer(pixelBuffer: outputBuffer))
    }

    private func cacheMask(inputBuffer: CVPixelBuffer, inputDimensions: CGSize) {
        guard frameCount % segmentationFrameInterval == 0 else { return }

        segmentationQueue.async {
            #if LK_SIGNPOSTS
            os_signpost(.begin, log: self.signpostLog, name: "segmentation")
            defer {
                os_signpost(.end, log: self.signpostLog, name: "segmentation")
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

            // Invert the mask so that the person is not blurred, just the background
            self.invertFilter.inputImage = maskImage.transformed(by: scaleTransform)
            self.cachedMaskImage = self.invertFilter.outputImage
        }
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
