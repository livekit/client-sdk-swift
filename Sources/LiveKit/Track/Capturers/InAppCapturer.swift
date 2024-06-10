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

#if canImport(ReplayKit)
import ReplayKit
#endif

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@available(macOS 11.0, iOS 11.0, *)
public class InAppScreenCapturer: VideoCapturer {
    private let capturer = RTC.createVideoCapturer()
    private let options: ScreenShareCaptureOptions

    init(delegate: LKRTCVideoCapturerDelegate, options: ScreenShareCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    override public func startCapture() async throws -> Bool {
        let didStart = try await super.startCapture()

        // Already started
        guard didStart else { return false }

        // TODO: force pixel format kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        try await RPScreenRecorder.shared().startCapture { [weak self] sampleBuffer, type, _ in
            guard let self else { return }
            // Only process .video
            if type == .video {
                self.capture(sampleBuffer: sampleBuffer, capturer: self.capturer, options: self.options)
            }
        }

        return true
    }

    override public func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }

        RPScreenRecorder.shared().stopCapture()

        return true
    }
}

public extension LocalVideoTrack {
    /// Creates a track that captures in-app screen only (due to limitation of ReplayKit)
    @available(macOS 11.0, iOS 11.0, *)
    static func createInAppScreenShareTrack(name: String = Track.screenShareVideoName,
                                            options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                            reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: true)
        let capturer = InAppScreenCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(name: name,
                               source: .screenShareVideo,
                               capturer: capturer,
                               videoSource: videoSource,
                               reportStatistics: reportStatistics)
    }
}
