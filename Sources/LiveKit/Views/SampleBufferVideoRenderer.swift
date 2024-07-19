/*
 * Copyright 2024 LiveKit
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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

class SampleBufferVideoRenderer: NativeView, Loggable {
    public let sampleBufferDisplayLayer: AVSampleBufferDisplayLayer
    
    private var firstFrameReceived = false
    private var bufferTransform = CATransform3DIdentity
    private var mirroredTransform = CATransform3DIdentity
    private var displayLayerTransform: CATransform3D {
        return CATransform3DConcat(bufferTransform, mirroredTransform)
    }

    override init(frame: CGRect) {
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        super.init(frame: frame)
        sampleBufferDisplayLayer.videoGravity = .resizeAspectFill
        #if os(macOS)
        // this is required for macOS
        wantsLayer = true
        layer?.insertSublayer(sampleBufferDisplayLayer, at: 0)
        #elseif os(iOS)
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
        sampleBufferDisplayLayer.frame = bounds
        sampleBufferDisplayLayer.removeAllAnimations()
    }
}

extension SampleBufferVideoRenderer: LKRTCVideoRenderer {
    func setSize(_: CGSize) {
        //
    }

    func renderFrame(_ frame: LKRTCVideoFrame?) {
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
        
        if !firstFrameReceived {
            bufferTransform = .fromFrameRotation(frame)
            updateSampleBufferTransform()
            firstFrameReceived = true
        }

        Task.detached { @MainActor in
            self.sampleBufferDisplayLayer.enqueue(sampleBuffer)
        }
    }
}

extension SampleBufferVideoRenderer: Mirrorable {
    func set(mirrored: Bool) {
        mirroredTransform = mirrored ? VideoView.mirrorTransform : CATransform3DIdentity
        updateSampleBufferTransform()
    }
}

private extension SampleBufferVideoRenderer {
    private func updateSampleBufferTransform() {
        sampleBufferDisplayLayer.transform = displayLayerTransform
    }
}

private extension CATransform3D {
    static func fromFrameRotation(_ frame: LKRTCVideoFrame) -> CATransform3D {
        switch frame.rotation {
        case ._0:
            return CATransform3DIdentity
        case ._90:
            return CATransform3DMakeRotation(.pi / 2.0, 0, 0, 1)
        case ._180:
            return CATransform3DMakeRotation(.pi, 0, 0, 1)
        case ._270:
            return CATransform3DMakeRotation(-.pi / 0, 0, 0, 1)
        }
    }
}
