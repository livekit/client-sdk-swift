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

internal import LiveKitWebRTC

class SampleBufferVideoRenderer: NativeView, Loggable {
    let sampleBufferDisplayLayer: AVSampleBufferDisplayLayer

    private struct State {
        var isMirrored: Bool = false
        var videoRotation: VideoRotation = ._0
    }

    private let _state = StateSync(State())

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

        var pixelBuffer: CVPixelBuffer?

        if let rtcPixelBuffer = frame.buffer as? LKRTCCVPixelBuffer {
            pixelBuffer = rtcPixelBuffer.pixelBuffer
        } else if let rtcI420Buffer = frame.buffer as? LKRTCI420Buffer {
            pixelBuffer = rtcI420Buffer.toPixelBuffer()
        }

        guard let pixelBuffer else {
            log("pixelBuffer is nil", .error)
            return
        }

        guard let sampleBuffer = CMSampleBuffer.from(pixelBuffer) else {
            log("Failed to convert CVPixelBuffer to CMSampleBuffer", .error)
            return
        }

        let rotation = frame.rotation.toLKType()
        let didUpdateRotation = _state.mutate {
            let result = $0.videoRotation != rotation
            $0.videoRotation = rotation
            return result
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
