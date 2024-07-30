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

#if os(visionOS)
import ARKit
import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@available(visionOS 2.0, *)
public class ARCameraCapturer: VideoCapturer {
    private let capturer = RTC.createVideoCapturer()
    private let arKitSession = ARKitSession()
    private let cameraFrameProvider = CameraFrameProvider()

    /// The ``ARCaptureOptions`` used for this capturer.
    public let options: ARCameraCaptureOptions

    private var captureTask: Task<Void, Never>?

    init(delegate: LKRTCVideoCapturerDelegate, options: ARCameraCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    override public func startCapture() async throws -> Bool {
        let didStart = try await super.startCapture()
        // Already started
        guard didStart else { return false }

        try await ensureCameraAccessAuthorized()

        try await arKitSession.run([cameraFrameProvider])

        guard let format = CameraVideoFormat.supportedVideoFormats(for: .main, cameraPositions: [.left]).first,
              let frameUpdates = cameraFrameProvider.cameraFrameUpdates(for: format)
        else {
            throw LiveKitError(.invalidState)
        }

        captureTask = Task.detached { [weak self] in
            guard let self else { return }
            for await frame in frameUpdates {
                if let sample = frame.sample(for: .left) {
                    self.capture(pixelBuffer: sample.pixelBuffer, capturer: self.capturer, options: self.options)
                }
            }
        }

        return true
    }

    private func ensureCameraAccessAuthorized() async throws {
        let queryResult = await arKitSession.queryAuthorization(for: [.cameraAccess])
        switch queryResult[.cameraAccess] {
        case .denied: throw LiveKitError(.deviceAccessDenied)
        case .notDetermined:
            let requestResult = await arKitSession.requestAuthorization(for: [.cameraAccess])
            if requestResult[.cameraAccess] != .allowed {
                throw LiveKitError(.deviceAccessDenied)
            }
        case .allowed: return
        default: throw LiveKitError(.deviceAccessDenied)
        }
    }

    override public func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()
        // Already stopped
        guard didStop else { return false }

        arKitSession.stop()
        captureTask?.cancel()
        captureTask = nil

        return true
    }
}

@available(visionOS 2.0, *)
public extension LocalVideoTrack {
    /// Creates a track that can directly capture `CVPixelBuffer` or `CMSampleBuffer` for convenience
    static func createARCameraTrack(name: String = Track.cameraName,
                                    source: VideoTrack.Source = .camera,
                                    options: ARCameraCaptureOptions = ARCameraCaptureOptions(),
                                    reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: false)
        let capturer = ARCameraCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(name: name,
                               source: source,
                               capturer: capturer,
                               videoSource: videoSource,
                               reportStatistics: reportStatistics)
    }
}
#endif
