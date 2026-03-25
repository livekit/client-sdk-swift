/*
 * Copyright 2026 LiveKit
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

internal import LiveKitWebRTC

class SampleBufferVideoRenderer: NativeView, Loggable {
    let sampleBufferDisplayLayer: AVSampleBufferDisplayLayer

    private struct State {
        var isMirrored: Bool = false
        var videoRotation: VideoRotation = ._0
        var rotationChangeCount: Int = 0
    }

    private let _state = StateSync(State())
    private let _sampleBufferDisplayPixelBufferProvider = SampleBufferDisplayPixelBufferProvider()

    override init(frame: CGRect) {
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        super.init(frame: frame)
        sampleBufferDisplayLayer.videoGravity = .resizeAspectFill
        #if os(macOS)
        // this is required for macOS
        wantsLayer = true
        layer?.insertSublayer(sampleBufferDisplayLayer, at: 0)
        #elseif os(iOS) || os(visionOS) || os(tvOS)
        layer.insertSublayer(sampleBufferDisplayLayer, at: 0)
        #else
        fatalError("Unimplemented")
        #endif
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performLayout() {
        super.performLayout()

        let (rotation, isMirrored) = _state.read { ($0.videoRotation, $0.isMirrored) }
        sampleBufferDisplayLayer.transform = CATransform3D.from(rotation: rotation, isMirrored: isMirrored)
        sampleBufferDisplayLayer.frame = bounds

        sampleBufferDisplayLayer.removeAllAnimations()
    }
}

extension SampleBufferVideoRenderer: LKRTCVideoRenderer {
    nonisolated func setSize(_: CGSize) {}

    nonisolated func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }

        guard let pixelBuffer = _sampleBufferDisplayPixelBufferProvider.makePixelBuffer(from: frame.buffer) else {
            log("pixelBuffer is nil", .error)
            return
        }

        guard let sampleBuffer = CMSampleBuffer.from(pixelBuffer) else {
            log("Failed to convert CVPixelBuffer to CMSampleBuffer", .error)
            return
        }

        let rotation = frame.rotation.toLKType()
        let (didUpdateRotation, oldRotation, rotChangeCount) = _state.mutate {
            let old = $0.videoRotation
            let didChange = old != rotation
            $0.videoRotation = rotation
            if didChange {
                $0.rotationChangeCount += 1
            } else {
                $0.rotationChangeCount = 0
            }
            return (didChange, old, $0.rotationChangeCount)
        }

        if didUpdateRotation {
            log("[sampleBuffer] rotation: \(oldRotation) -> \(rotation), consecutiveChanges: \(rotChangeCount)")
        }

        Task { @MainActor in
            self.sampleBufferDisplayLayer.enqueue(sampleBuffer)
            if didUpdateRotation {
                self.setNeedsLayout()
            }
        }
    }
}

extension SampleBufferVideoRenderer: Mirrorable {
    func set(isMirrored: Bool) {
        let didUpdateIsMirrored = _state.mutate {
            let result = $0.isMirrored != isMirrored
            $0.isMirrored = isMirrored
            return result
        }

        if didUpdateIsMirrored {
            setNeedsLayout()
        }
    }
}

/// Produces `CVPixelBuffer`s that match the logical frame geometry expected by
/// `AVSampleBufferDisplayLayer`, including any WebRTC crop/scale metadata.
private final class SampleBufferDisplayPixelBufferProvider: @unchecked Sendable, Loggable {
    private struct PoolConfiguration: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    private struct State {
        var poolConfiguration: PoolConfiguration?
        var pixelBufferPool: CVPixelBufferPool?
    }

    private let _state = StateSync(State())

    func makePixelBuffer(from buffer: LKRTCVideoFrameBuffer) -> CVPixelBuffer? {
        if let rtcPixelBuffer = buffer as? LKRTCCVPixelBuffer {
            return makePixelBuffer(from: rtcPixelBuffer)
        }

        if let rtcI420Buffer = buffer as? LKRTCI420Buffer {
            return rtcI420Buffer.toPixelBuffer()
        }

        log("Unsupported video frame buffer type: \(type(of: buffer))", .error)
        return nil
    }

    private func makePixelBuffer(from buffer: LKRTCCVPixelBuffer) -> CVPixelBuffer? {
        // Fast path: the backing CVPixelBuffer already matches the logical frame.
        if !buffer.requiresCropping(), !buffer.requiresScaling(toWidth: buffer.width, height: buffer.height) {
            return buffer.pixelBuffer
        }

        let pixelBufferPool: CVPixelBufferPool? = _state.mutate { state in
            let configuration = PoolConfiguration(width: Int(buffer.width),
                                                  height: Int(buffer.height),
                                                  pixelFormat: CVPixelBufferGetPixelFormatType(buffer.pixelBuffer))

            if state.poolConfiguration != configuration {
                state.poolConfiguration = configuration
                state.pixelBufferPool = Self.makePixelBufferPool(configuration: configuration)
            }

            return state.pixelBufferPool
        }

        guard let pixelBufferPool else {
            log("Failed to create pixel buffer pool for sample-buffer rendering", .error)
            return nil
        }

        // Materialize a new CVPixelBuffer because AVSampleBufferDisplayLayer
        // cannot interpret RTCCVPixelBuffer crop metadata on its own.
        guard let outputPixelBuffer = Self.makePixelBuffer(from: pixelBufferPool) else {
            log("Failed to allocate pixel buffer for sample-buffer rendering", .error)
            return nil
        }

        let tempBufferSize = Int(buffer.bufferSizeForCroppingAndScaling(toWidth: buffer.width,
                                                                        height: buffer.height))

        let didCropAndScale: Bool
        if tempBufferSize > 0 {
            // Allocate scratch space locally so crop/scale work stays outside
            // the provider lock while keeping the implementation simple.
            var tempBuffer = [UInt8](repeating: .zero, count: tempBufferSize)
            didCropAndScale = tempBuffer.withUnsafeMutableBufferPointer {
                buffer.cropAndScale(to: outputPixelBuffer, withTempBuffer: $0.baseAddress)
            }
        } else {
            didCropAndScale = buffer.cropAndScale(to: outputPixelBuffer, withTempBuffer: nil)
        }

        guard didCropAndScale else {
            log("Failed to crop and scale RTCCVPixelBuffer for sample-buffer rendering", .error)
            return nil
        }

        return outputPixelBuffer
    }

    private static func makePixelBufferPool(configuration: PoolConfiguration) -> CVPixelBufferPool? {
        let options = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferWidthKey as String: configuration.width,
            kCVPixelBufferHeightKey as String: configuration.height,
            kCVPixelBufferPixelFormatTypeKey as String: configuration.pixelFormat,
        ] as [String: Any]

        let poolAttributes = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ] as CFDictionary

        var pixelBufferPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttributes,
                                             options as CFDictionary,
                                             &pixelBufferPool)

        guard status == kCVReturnSuccess else {
            return nil
        }

        return pixelBufferPool
    }

    private static func makePixelBuffer(from pixelBufferPool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                        pixelBufferPool,
                                                        &pixelBuffer)

        guard status == kCVReturnSuccess else {
            return nil
        }

        return pixelBuffer
    }
}

extension CATransform3D {
    static let mirror = CATransform3DMakeScale(-1.0, 1.0, 1.0)

    static func from(rotation: VideoRotation, isMirrored: Bool) -> CATransform3D {
        var transform: CATransform3D = switch rotation {
        case ._0:
            CATransform3DIdentity
        case ._90:
            CATransform3DMakeRotation(.pi / 2.0, 0, 0, 1)
        case ._180:
            CATransform3DMakeRotation(.pi, 0, 0, 1)
        case ._270:
            CATransform3DMakeRotation(-.pi / 2.0, 0, 0, 1)
        }

        if isMirrored {
            transform = CATransform3DConcat(transform, mirror)
        }

        return transform
    }
}
