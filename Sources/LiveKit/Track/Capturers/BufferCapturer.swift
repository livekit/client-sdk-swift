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

import CoreMedia
import Foundation

internal import LiveKitWebRTC

/// A ``VideoCapturer`` that can capture ``CMSampleBuffer``s.
///
/// Repeatedly call ``capture(_:)`` to capture a stream of ``CMSampleBuffer``s.
/// The pixel format must be one of ``VideoCapturer/supportedPixelFormats``. If an unsupported pixel format is used, the SDK will skip the capture.
/// ``BufferCapturer`` can be used to provide video buffers from ReplayKit.
///
/// > Note: At least one frame must be captured before publishing the track or the publish will timeout,
/// since dimensions must be resolved at the time of publishing (to compute video parameters).
///
public class BufferCapturer: VideoCapturer, @unchecked Sendable {
    private let capturer = RTC.createVideoCapturer()

    /// The ``BufferCaptureOptions`` used for this capturer.
    public let options: BufferCaptureOptions

    init(delegate: LKRTCVideoCapturerDelegate, options: BufferCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    /// Capture a ``CMSampleBuffer``.
    public func capture(_ sampleBuffer: CMSampleBuffer) {
        capture(sampleBuffer: sampleBuffer,
                capturer: capturer,
                options: options)
    }

    /// Capture a ``CVPixelBuffer``.
    public func capture(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64 = VideoCapturer.createTimeStampNs(), rotation: VideoRotation = ._0) {
        capture(pixelBuffer: pixelBuffer,
                capturer: capturer,
                timeStampNs: timeStampNs,
                rotation: rotation,
                options: options)
    }
}

public extension LocalVideoTrack {
    /// Creates a track that can directly capture `CVPixelBuffer` or `CMSampleBuffer` for convienience
    @available(*, deprecated, message: "Blocks the calling thread until WebRTC's factory responds; use the async variant instead.")
    static func createBufferTrack(name: String = Track.screenShareVideoName,
                                  source: Track.Source = .screenShareVideo,
                                  options: BufferCaptureOptions = BufferCaptureOptions(),
                                  reportStatistics: Bool = false) -> LocalVideoTrack
    {
        _createBufferTrack(name: name, source: source, options: options, reportStatistics: reportStatistics)
    }

    /// Creates a buffer track on the RTC executor: the calling task suspends instead of
    /// blocking its thread on WebRTC's factory.
    static func createBufferTrack(name: String = Track.screenShareVideoName,
                                  source: Track.Source = .screenShareVideo,
                                  options: BufferCaptureOptions = BufferCaptureOptions(),
                                  reportStatistics: Bool = false) async -> LocalVideoTrack
    {
        await RTC.run { _createBufferTrack(name: name, source: source, options: options, reportStatistics: reportStatistics) }
    }

    internal static func _createBufferTrack(name: String,
                                            source: Track.Source,
                                            options: BufferCaptureOptions,
                                            reportStatistics: Bool) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: source == .screenShareVideo)
        let capturer = BufferCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(name: name,
                               source: source,
                               capturer: capturer,
                               videoSource: videoSource,
                               reportStatistics: reportStatistics)
    }
}
