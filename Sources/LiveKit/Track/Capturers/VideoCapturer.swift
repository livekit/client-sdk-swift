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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

protocol VideoCapturerProtocol {
    var capturer: LKRTCVideoCapturer { get }
}

extension VideoCapturerProtocol {
    public var capturer: LKRTCVideoCapturer { fatalError("Must be implemented") }
}

@objc
public protocol VideoCapturerDelegate: AnyObject {
    @objc(capturer:didUpdateDimensions:) optional
    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?)

    @objc(capturer:didUpdateState:) optional
    func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.CapturerState)
}

// Intended to be a base class for video capturers
public class VideoCapturer: NSObject, Loggable, VideoCapturerProtocol {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<VideoCapturerDelegate>(label: "VideoCapturerDelegate")
    public let rendererDelegates = MulticastDelegate<VideoRenderer>(label: "VideoCapturerRendererDelegate")

    /// Array of supported pixel formats that can be used to capture a frame.
    ///
    /// Usually the following formats are supported but it is recommended to confirm at run-time:
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`,
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`,
    /// `kCVPixelFormatType_32BGRA`,
    /// `kCVPixelFormatType_32ARGB`.
    public static let supportedPixelFormats = DispatchQueue.liveKitWebRTC.sync { LKRTCCVPixelBuffer.supportedPixelFormats() }

    public static func createTimeStampNs() -> Int64 {
        let systemTime = ProcessInfo.processInfo.systemUptime
        return Int64(systemTime * Double(NSEC_PER_SEC))
    }

    @objc
    public enum CapturerState: Int {
        case stopped
        case started
    }

    private weak var delegate: LKRTCVideoCapturerDelegate?

    let dimensionsCompleter = AsyncCompleter<Dimensions>(label: "Dimensions", defaultTimeout: .defaultCaptureStart)

    struct State: Equatable {
        // Counts calls to start/stopCapturer so multiple Tracks can use the same VideoCapturer.
        var startStopCounter: Int = 0
        var dimensions: Dimensions? = nil
    }

    var _state = StateSync(State())

    public var dimensions: Dimensions? { _state.dimensions }

    func set(dimensions newValue: Dimensions?) {
        let didUpdate = _state.mutate {
            let oldDimensions = $0.dimensions
            $0.dimensions = newValue
            return newValue != oldDimensions
        }

        if didUpdate {
            delegates.notify { $0.capturer?(self, didUpdate: newValue) }

            if let newValue {
                log("[publish] dimensions: \(String(describing: newValue))")
                dimensionsCompleter.resume(returning: newValue)
            } else {
                dimensionsCompleter.reset()
            }
        }
    }

    public var captureState: CapturerState {
        _state.startStopCounter == 0 ? .stopped : .started
    }

    init(delegate: LKRTCVideoCapturerDelegate) {
        self.delegate = delegate
        super.init()

        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self else { return }
            if oldState.startStopCounter != newState.startStopCounter {
                self.log("startStopCounter \(oldState.startStopCounter) -> \(newState.startStopCounter)")
            }
        }
    }

    deinit {
        if captureState != .stopped {
            log("captureState is not .stopped, capturer must be stopped before deinit.", .error)
        }
    }

    /// Requests video capturer to start generating frames. ``Track/start()-dk8x`` calls this automatically.
    ///
    /// ``startCapture()`` and ``stopCapture()`` calls must be balanced. For example, if ``startCapture()`` is called 2 times, ``stopCapture()`` must be called 2 times also.
    /// Returns true when capturing should start, returns fals if capturing already started.
    @objc
    @discardableResult
    public func startCapture() async throws -> Bool {
        let didStart = _state.mutate {
            // Counter was 0, so did start capturing with this call
            let didStart = $0.startStopCounter == 0
            $0.startStopCounter += 1
            return didStart
        }

        guard didStart else {
            // Already started
            return false
        }

        delegates.notify(label: { "capturer.didUpdate state: \(CapturerState.started)" }) {
            $0.capturer?(self, didUpdate: .started)
        }

        return true
    }

    /// Requests video capturer to stop generating frames. ``Track/stop()-6jeq0`` calls this automatically.
    ///
    /// See ``startCapture()`` for more details.
    /// Returns true when capturing should stop, returns fals if capturing already stopped.
    @objc
    @discardableResult
    public func stopCapture() async throws -> Bool {
        let didStop = _state.mutate {
            // Counter was already 0, so did NOT stop capturing with this call
            if $0.startStopCounter <= 0 {
                return false
            }
            $0.startStopCounter -= 1
            return $0.startStopCounter <= 0
        }

        guard didStop else {
            // Already stopped
            return false
        }

        delegates.notify(label: { "capturer.didUpdate state: \(CapturerState.stopped)" }) {
            $0.capturer?(self, didUpdate: .stopped)
        }

        dimensionsCompleter.reset()

        return true
    }

    @objc
    @discardableResult
    public func restartCapture() async throws -> Bool {
        try await stopCapture()
        return try await startCapture()
    }
}

extension VideoCapturer {
    // Capture a RTCVideoFrame
    func capture(frame: LKRTCVideoFrame,
                 capturer: LKRTCVideoCapturer,
                 device: AVCaptureDevice? = nil,
                 options: VideoCaptureOptions)
    {
        _processFrame(frame, capturer: capturer, device: device, options: options)
    }

    // Capture a CMSampleBuffer
    func capture(sampleBuffer: CMSampleBuffer,
                 capturer: LKRTCVideoCapturer,
                 options: VideoCaptureOptions)
    {
        delegate?.capturer(capturer, didCapture: sampleBuffer) { [weak self] frame in
            self?._processFrame(frame, capturer: capturer, device: nil, options: options)
        }
    }

    // Capture a CVPixelBuffer
    func capture(pixelBuffer: CVPixelBuffer,
                 capturer: LKRTCVideoCapturer,
                 timeStampNs: Int64 = VideoCapturer.createTimeStampNs(),
                 rotation: VideoRotation = ._0,
                 options: VideoCaptureOptions)
    {
        delegate?.capturer(capturer, didCapture: pixelBuffer, timeStampNs: timeStampNs, rotation: rotation.toRTCType()) { [weak self] frame in
            self?._processFrame(frame, capturer: capturer, device: nil, options: options)
        }
    }

    // Process the captured frame
    private func _processFrame(_ frame: LKRTCVideoFrame,
                               capturer: LKRTCVideoCapturer,
                               device: AVCaptureDevice?,
                               options: VideoCaptureOptions)
    {
        // Resolve real dimensions (apply frame rotation)
        set(dimensions: Dimensions(width: frame.width, height: frame.height).apply(rotation: frame.rotation))

        delegate?.capturer(capturer, didCapture: frame)

        if rendererDelegates.isDelegatesNotEmpty {
            if let lkVideoFrame = frame.toLKType() {
                rendererDelegates.notify { renderer in
                    renderer.render?(frame: lkVideoFrame)
                    renderer.render?(frame: lkVideoFrame, captureDevice: device, captureOptions: options)
                }
            }
        }
    }
}
