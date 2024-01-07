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

import Foundation

@_implementationOnly import WebRTC

class SampleBufferVideoRenderer: NativeView, Loggable {
    public let sampleBufferDisplayLayer: AVSampleBufferDisplayLayer

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

        Task { @MainActor in
            sampleBufferDisplayLayer.enqueue(sampleBuffer)
        }
    }
}

extension SampleBufferVideoRenderer: Mirrorable {
    func set(mirrored: Bool) {
        sampleBufferDisplayLayer.transform = mirrored ? VideoView.mirrorTransform : CATransform3DIdentity
    }
}
