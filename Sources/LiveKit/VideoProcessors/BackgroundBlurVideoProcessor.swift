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
    private let segmentationFrameInterval = 2
    #endif

    // MARK: CoreImage

    private let ciContext: CIContext = .metal

    private let invertFilter = CIFilter.colorInvert()
    private let blurFilter = CIFilter.maskedVariableBlur()

    // MARK: Cache

    private var lastInputDimensions: CGSize = .zero
    private var lastMaskDimensions: CGSize = .zero
    private var scaleTransform: CGAffineTransform = .identity

    private var outputPixelBuffer: CVPixelBuffer?
    private var outputBufferDimensions: CGSize?

    private var lastMaskImage: CIImage?

    // MARK: Init

    public init(intensity: CGFloat = 0.01) {
        self.intensity = intensity
    }

    // MARK: VideoProcessor

    public func process(frame: VideoFrame) -> VideoFrame? {
        guard let pixelBuffer = frame.toCVPixelBuffer() else {
            return frame
        }

        frameCount += 1

        if frameCount % segmentationFrameInterval == 0 {
            segmentationQueue.async {
                try? self.segmentationRequestHandler.perform([self.segmentationRequest], on: pixelBuffer)

                if let maskPixelBuffer = self.segmentationRequest.results?.first?.pixelBuffer {
                    self.lastMaskImage = CIImage(cvPixelBuffer: maskPixelBuffer)
                }
            }
        }

        let maskImage = lastMaskImage

        guard let maskImage else {
            return frame
        }

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)

        let inputDimensions = inputImage.extent.size
        let maskDimensions = maskImage.extent.size

        if lastInputDimensions != inputDimensions || lastMaskDimensions != maskDimensions {
            let scaleX = inputDimensions.width / maskDimensions.width
            let scaleY = inputDimensions.height / maskDimensions.height
            scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)

            lastInputDimensions = inputDimensions
            lastMaskDimensions = maskDimensions

            outputBufferDimensions = nil
        }

        invertFilter.inputImage = maskImage.transformed(by: scaleTransform)

        guard let invertedMask = invertFilter.outputImage else {
            return frame
        }

        blurFilter.inputImage = inputImage
        blurFilter.mask = invertedMask
        blurFilter.radius = Float(intensity * min(lastInputDimensions.width, lastInputDimensions.height))

        guard let outputImage = blurFilter.outputImage?.cropped(to: inputImage.extent) else {
            return frame
        }

        if outputBufferDimensions != inputDimensions {
            outputPixelBuffer = .metal(width: Int(inputDimensions.width), height: Int(inputDimensions.height))
            outputBufferDimensions = inputDimensions
        }

        guard let outputBuffer = outputPixelBuffer else {
            return frame
        }

        ciContext.render(outputImage, to: outputBuffer)

        return VideoFrame(dimensions: frame.dimensions,
                          rotation: frame.rotation,
                          timeStampNs: frame.timeStampNs,
                          buffer: CVPixelVideoBuffer(pixelBuffer: outputBuffer))
    }
}

extension CVPixelBuffer: @unchecked Swift.Sendable {}
