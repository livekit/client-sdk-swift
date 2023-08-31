/*
 * Copyright 2022 LiveKit
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
import WebRTC
import Promises

/// A ``VideoCapturer`` that can capture ``CMSampleBuffer``s.
///
/// Repeatedly call ``capture(_:)`` to capture a stream of ``CMSampleBuffer``s.
/// The pixel format must be one of ``VideoCapturer/supportedPixelFormats``. If an unsupported pixel format is used, the SDK will skip the capture.
/// ``BufferCapturer`` can be used to provide video buffers from ReplayKit.
///
/// > Note: At least one frame must be captured before publishing the track or the publish will timeout,
/// since dimensions must be resolved at the time of publishing (to compute video parameters).
///
public class BufferCapturer: VideoCapturer {

    private let capturer = Engine.createVideoCapturer()

    /// The ``BufferCaptureOptions`` used for this capturer.
    public var options: BufferCaptureOptions

    init(delegate: RTCVideoCapturerDelegate, options: BufferCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    /// Capture a ``CMSampleBuffer``.
    public func capture(_ sampleBuffer: CMSampleBuffer) {

        delegate?.capturer(capturer, didCapture: sampleBuffer) { sourceDimensions in

            let targetDimensions = sourceDimensions
                .aspectFit(size: self.options.dimensions.max)
                .toEncodeSafeDimensions()

            defer { self.dimensions = targetDimensions }

            guard let videoSource = self.delegate as? RTCVideoSource else { return }
            videoSource.adaptOutputFormat(toWidth: targetDimensions.width,
                                          height: targetDimensions.height,
                                          fps: Int32(self.options.fps))
        }
    }

    /// Capture a ``CVPixelBuffer``.
    public func capture(_ pixelBuffer: CVPixelBuffer,
                        timeStampNs: Int64 = VideoCapturer.createTimeStampNs(),
                        rotation: RTCVideoRotation = ._0) {

        delegate?.capturer(capturer,
                           didCapture: pixelBuffer,
                           timeStampNs: timeStampNs,
                           rotation: rotation) { sourceDimensions in

            let targetDimensions = sourceDimensions
                .aspectFit(size: self.options.dimensions.max)
                .toEncodeSafeDimensions()

            defer { self.dimensions = targetDimensions }

            guard let videoSource = self.delegate as? RTCVideoSource else { return }
            videoSource.adaptOutputFormat(toWidth: targetDimensions.width,
                                          height: targetDimensions.height,
                                          fps: Int32(self.options.fps))
        }
    }
}

extension LocalVideoTrack {

    /// Creates a track that can directly capture `CVPixelBuffer` or `CMSampleBuffer` for convienience
    public static func createBufferTrack(name: String = Track.screenShareVideoName,
                                         source: VideoTrack.Source = .screenShareVideo,
                                         options: BufferCaptureOptions = BufferCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: source == .screenShareVideo)
        let capturer = CameraInterceptBufferCapturer(delegate: videoSource)
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}

public class CameraInterceptBufferCapturer: BufferCapturer, RTCVideoCapturerDelegate {

    lazy var cameraCapturer: CameraCapturer = {
        CameraCapturer(delegate: self, options: CameraCaptureOptions(dimensions: .h1080_169, fps: 30))
    }()

    init(delegate: RTCVideoCapturerDelegate) {
        super.init(delegate: delegate, options: BufferCaptureOptions())
    }

    // RTCVideoCapturerDelegate
    public func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        print("Interceped frame from CameraCapturer")

        if let rtcCVPixelBuffer = frame.buffer as? RTCCVPixelBuffer {

            // Relay frame to BufferCapturer
            capture(rtcCVPixelBuffer.pixelBuffer)
        }
    }

    public override var captureState: VideoCapturer.CapturerState {
        cameraCapturer.captureState
    }

    public override func startCapture() -> Promise<Bool> {
        cameraCapturer.startCapture()
    }

    public override func stopCapture() -> Promise<Bool> {
        cameraCapturer.stopCapture()
    }
}
