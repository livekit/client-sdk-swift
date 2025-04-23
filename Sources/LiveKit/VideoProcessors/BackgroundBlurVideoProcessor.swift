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
import CoreVideo
import Vision

@available(iOS 15.0, macOS 12.0, *)
@objc
public final class BackgroundBlurVideoProcessor: NSObject, @unchecked Sendable, VideoProcessor, Loggable {
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

    private let ciContext: CIContext = .metal

    private let invertFilter = CIFilter.colorInvert()
    private let blurFilter = CIFilter.maskedVariableBlur()

    // MARK: Cache

    private var cachedMaskImage: CIImage?

    private var cachedPixelBuffer: CVPixelBuffer?
    private var cachedPixelBufferSize: CGSize?

    // MARK: Init

    public init(intensity: CGFloat = 0.01) {
        self.intensity = intensity
    }

    // MARK: VideoProcessor

    public func process(frame: VideoFrame) -> VideoFrame? {
        guard let pixelBuffer = frame.toCVPixelBuffer() else { return frame }

        frameCount += 1

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let inputDimensions = inputImage.extent.size

        if frameCount % segmentationFrameInterval == 0 {
            segmentationQueue.async {
                try? self.segmentationRequestHandler.perform([self.segmentationRequest], on: pixelBuffer)

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

        let mask = cachedMaskImage

        guard let mask else { return frame }

        blurFilter.inputImage = inputImage
        blurFilter.mask = mask
        blurFilter.radius = Float(intensity * min(inputDimensions.width, inputDimensions.height))

        guard let outputImage = blurFilter.outputImage?.cropped(to: inputImage.extent) else { return frame }

        // Recreate buffer if needed
        if cachedPixelBufferSize != inputDimensions {
            cachedPixelBuffer = .metal(width: Int(inputDimensions.width), height: Int(inputDimensions.height))
            cachedPixelBufferSize = inputDimensions
        }

        guard let outputBuffer = cachedPixelBuffer else { return frame }

        ciContext.render(outputImage, to: outputBuffer)

        return VideoFrame(dimensions: frame.dimensions,
                          rotation: frame.rotation,
                          timeStampNs: frame.timeStampNs,
                          buffer: CVPixelVideoBuffer(pixelBuffer: outputBuffer))
    }
}

extension CVPixelBuffer: @unchecked Swift.Sendable {}
