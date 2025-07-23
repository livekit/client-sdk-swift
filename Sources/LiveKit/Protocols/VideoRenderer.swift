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

import AVFoundation

internal import LiveKitWebRTC

@objc
public protocol VideoRenderer: Sendable {
    /// Whether this ``VideoRenderer`` should be considered visible or not for AdaptiveStream.
    /// This will be invoked on the .main thread.
    @objc
    @MainActor var isAdaptiveStreamEnabled: Bool { get }
    /// The size used for AdaptiveStream computation. Return .zero if size is unknown yet.
    /// This will be invoked on the .main thread.
    @objc
    @MainActor var adaptiveStreamSize: CGSize { get }

    /// Size of the frame.
    @objc optional
    nonisolated func set(size: CGSize)

    /// A ``VideoFrame`` is ready and should be processed.
    @objc optional
    nonisolated func render(frame: VideoFrame)

    /// In addition to ``VideoFrame``, provide capture-time information if available.
    @objc optional
    nonisolated func render(frame: VideoFrame, captureDevice: AVCaptureDevice?, captureOptions: VideoCaptureOptions?)
}

class VideoRendererAdapter: NSObject, LKRTCVideoRenderer {
    private weak var target: VideoRenderer?

    init(target: VideoRenderer) {
        self.target = target
    }

    func setSize(_ size: CGSize) {
        target?.set?(size: size)
    }

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame = frame?.toLKType() else { return }
        target?.render?(frame: frame)
        target?.render?(frame: frame, captureDevice: nil, captureOptions: nil)
    }

    // Proxy the equality operators

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? VideoRendererAdapter else { return false }
        return target === other.target
    }

    override var hash: Int {
        guard let target else { return 0 }
        return ObjectIdentifier(target).hashValue
    }
}
