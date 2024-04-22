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

import AVFoundation
import Foundation

@_implementationOnly import LiveKitWebRTC

@objc
public protocol VideoRenderer {
    /// Whether this ``VideoRenderer`` should be considered visible or not for AdaptiveStream.
    /// This will be invoked on the .main thread.
    @objc
    var isAdaptiveStreamEnabled: Bool { get }
    /// The size used for AdaptiveStream computation. Return .zero if size is unknown yet.
    /// This will be invoked on the .main thread.
    @objc
    var adaptiveStreamSize: CGSize { get }

    /// Size of the frame.
    @objc optional
    func set(size: CGSize)

    @objc optional
    func render(frame: VideoFrame)

    // Only invoked for local tracks, provides additional capture time options
    @objc optional
    func render(frame: VideoFrame, videoCaptureOptions: VideoCaptureOptions?)
}

class VideoRendererAdapter: NSObject, LKRTCVideoRenderer {
    private weak var target: VideoRenderer?
    private weak var localVideoTrack: LocalVideoTrack?

    init(target: VideoRenderer, localVideoTrack: LocalVideoTrack?) {
        self.target = target
        self.localVideoTrack = localVideoTrack
    }

    func setSize(_ size: CGSize) {
        target?.set?(size: size)
    }

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame = frame?.toLKType() else { return }
        target?.render?(frame: frame)

        let cameraCapturer = localVideoTrack?.capturer as? CameraCapturer
        target?.render?(frame: frame, videoCaptureOptions: cameraCapturer?.options)
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
