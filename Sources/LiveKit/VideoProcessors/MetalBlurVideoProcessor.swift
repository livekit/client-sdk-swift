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

import CoreVideo
import Metal
import Vision

#if LK_SIGNPOSTS
import os.signpost
#endif

/// A ``VideoProcessor`` that blurs the background of a video stream using Metal for high-performance processing.
///
/// This processor uses Vision to generate a mask of the person in the video stream and then applies a Metal shader
/// to directly blur the background of the YUV input buffer, taking advantage of GPU acceleration.
///
@available(iOS 15.0, macOS 12.0, tvOS 15.0, visionOS 1.0, *)
@objc
public final class MetalBlurVideoProcessor: NSObject, @unchecked Sendable, VideoProcessor, Loggable {
    #if LK_SIGNPOSTS
    private let signpostLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "", category: "MetalBlur")
    #endif

    // MARK: Parameters

    public let intensity: Float

    // MARK: Vision

    private let segmentationRequest = {
        let segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = .balanced
        return segmentationRequest
    }()

    private let segmentationRequestHandler = VNSequenceRequestHandler()
    // Matches Vision internal QoS to avoid priority inversion
    private let segmentationQueue = DispatchQueue(label: "io.livekit.metalblur.segmentation", qos: .default, autoreleaseFrequency: .workItem)

    // MARK: Performance

    private var frameCount = 0
    #if os(macOS)
    private let segmentationFrameInterval = 1
    #else
    private let segmentationFrameInterval = 3
    #endif

    // MARK: Metal

    private let metalDevice: MTLDevice
    private let metalCommandQueue: MTLCommandQueue
    private let metalPipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    // MARK: Cache

    private var cachedMaskPixelBuffer: CVPixelBuffer?
    private var cachedOutputBuffer: CVPixelBuffer?
    private var cachedOutputSize: CGSize?

    // MARK: Init

    /// - Parameters:
    ///   - intensity: The intensity of the blur effect, relative to the smallest dimension of the video frame.
    public init(intensity: Float = 0.01) {
        self.intensity = intensity

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            fatalError("Failed to create Metal device or command queue")
        }

        metalDevice = device
        metalCommandQueue = commandQueue

        var library: MTLLibrary?
        do {
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            fatalError("Failed to load Metal library: \(error)")
        }

        guard let library,
              let maskedBlurFunction = library.makeFunction(name: "maskedBlur")
        else {
            fatalError("Failed to load maskedBlur function from Metal library")
        }

        do {
            metalPipelineState = try device.makeComputePipelineState(function: maskedBlurFunction)
        } catch {
            fatalError("Failed to create compute pipeline state: \(error)")
        }

        var metalTextureCache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache)
        if result != kCVReturnSuccess {
            fatalError("Failed to create Metal texture cache")
        }
        textureCache = metalTextureCache

        super.init()
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

        let pixelFormat = CVPixelBufferGetPixelFormatType(inputBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        else {
            // TODO: Handle single plane?
            log("Input buffer is not a biplanar YUV format (got \(pixelFormat.toString())), returning original frame", .warning)
            return frame
        }

        let inputDimensions = CGSize(width: CVPixelBufferGetWidth(inputBuffer), height: CVPixelBufferGetHeight(inputBuffer))

        guard let outputBuffer = getYUVOutputBuffer(of: inputDimensions, format: pixelFormat) else {
            log("Failed to create output buffer", .error)
            return frame
        }

        updateMask(for: inputBuffer, with: inputDimensions)

        guard let maskBuffer = cachedMaskPixelBuffer else {
            log("No mask available yet, returning original frame", .debug)
            return frame
        }

        if !applyMetalMaskedBlur(inputBuffer: inputBuffer, maskBuffer: maskBuffer, outputBuffer: outputBuffer) {
            log("Metal masked blur processing failed, returning original frame", .error)
            return frame
        }

        return VideoFrame(dimensions: frame.dimensions,
                          rotation: frame.rotation,
                          timeStampNs: frame.timeStampNs,
                          buffer: CVPixelVideoBuffer(pixelBuffer: outputBuffer))
    }

    // MARK: - Private Methods

    private func updateMask(for inputBuffer: CVPixelBuffer, with _: CGSize) {
        guard frameCount % segmentationFrameInterval == 0 else { return }

        segmentationQueue.async { [weak self] in
            guard let self else { return }

            #if LK_SIGNPOSTS
            os_signpost(.begin, log: self.signpostLog, name: "segmentation")
            defer {
                os_signpost(.end, log: self.signpostLog, name: "segmentation")
            }
            #endif

            try? self.segmentationRequestHandler.perform([self.segmentationRequest], on: inputBuffer)

            guard let maskPixelBuffer = self.segmentationRequest.results?.first?.pixelBuffer else { return }
            self.cachedMaskPixelBuffer = maskPixelBuffer
        }
    }

    private func getYUVOutputBuffer(of size: CGSize, format: OSType) -> CVPixelBuffer? {
        if cachedOutputSize != size {
            let attributes = [
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue as Any,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as Any,
                kCVPixelBufferPixelFormatTypeKey: format, // Use input format
            ] as CFDictionary

            var pixelBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault,
                                             Int(size.width),
                                             Int(size.height),
                                             format,
                                             attributes,
                                             &pixelBuffer)

            guard result == kCVReturnSuccess, let newBuffer = pixelBuffer else { return nil }

            cachedOutputBuffer = newBuffer
            cachedOutputSize = size
        }

        return cachedOutputBuffer
    }

    private func applyMetalMaskedBlur(inputBuffer: CVPixelBuffer, maskBuffer: CVPixelBuffer, outputBuffer: CVPixelBuffer) -> Bool {
        guard let textureCache else { return false }

        let width = CVPixelBufferGetWidth(inputBuffer)
        let height = CVPixelBufferGetHeight(inputBuffer)

        var lumaInTexture: CVMetalTexture?
        var chromaInTexture: CVMetalTexture?
        var maskTexture: CVMetalTexture?
        var lumaOutTexture: CVMetalTexture?
        var chromaOutTexture: CVMetalTexture?

        let lumaInResult = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, inputBuffer, nil, .r8Unorm, width, height, 0, &lumaInTexture)
        let chromaInResult = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, inputBuffer, nil, .rg8Unorm, width / 2, height / 2, 1, &chromaInTexture)
        let maskWidth = CVPixelBufferGetWidth(maskBuffer)
        let maskHeight = CVPixelBufferGetHeight(maskBuffer)
        let maskResult = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, maskBuffer, nil, .r8Unorm, maskWidth, maskHeight, 0, &maskTexture)
        let lumaOutResult = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, outputBuffer, nil, .r8Unorm, width, height, 0, &lumaOutTexture)
        let chromaOutResult = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, outputBuffer, nil, .rg8Unorm, width / 2, height / 2, 1, &chromaOutTexture)

        guard lumaInResult == kCVReturnSuccess,
              chromaInResult == kCVReturnSuccess,
              maskResult == kCVReturnSuccess,
              lumaOutResult == kCVReturnSuccess,
              chromaOutResult == kCVReturnSuccess,
              let lumaInTexture,
              let chromaInTexture,
              let maskTexture,
              let lumaOutTexture,
              let chromaOutTexture,
              let lumaInTextureRef = CVMetalTextureGetTexture(lumaInTexture),
              let chromaInTextureRef = CVMetalTextureGetTexture(chromaInTexture),
              let maskTextureRef = CVMetalTextureGetTexture(maskTexture),
              let lumaOutTextureRef = CVMetalTextureGetTexture(lumaOutTexture),
              let chromaOutTextureRef = CVMetalTextureGetTexture(chromaOutTexture)
        else {
            log("Failed to create Metal textures from pixel buffers", .error)
            return false
        }

        guard let commandBuffer = metalCommandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder()
        else {
            log("Failed to create Metal command buffer or compute encoder", .error)
            return false
        }

        computeEncoder.setComputePipelineState(metalPipelineState)

        computeEncoder.setTexture(lumaInTextureRef, index: 0)
        computeEncoder.setTexture(chromaInTextureRef, index: 1)
        computeEncoder.setTexture(maskTextureRef, index: 2)
        computeEncoder.setTexture(lumaOutTextureRef, index: 3)
        computeEncoder.setTexture(chromaOutTextureRef, index: 4)

        var blurRadius = 100
        computeEncoder.setBytes(&blurRadius, length: MemoryLayout<Float>.size, index: 0)

        // TODO: Tweak that
        let threadGroupSize = MTLSize(width: 4, height: 4, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        CVMetalTextureCacheFlush(textureCache, 0)

        return true
    }
}
