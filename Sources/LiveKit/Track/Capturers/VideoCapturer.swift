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

@preconcurrency import AVFoundation
import Foundation

internal import LiveKitWebRTC

#if canImport(ReplayKit)
import ReplayKit
#endif

protocol VideoCapturerProtocol {
    var capturer: LKRTCVideoCapturer { get }
}

extension VideoCapturerProtocol {
    public var capturer: LKRTCVideoCapturer { fatalError("Must be implemented") }
}

@objc
public protocol VideoCapturerDelegate: AnyObject, Sendable {
    @objc(capturer:didUpdateDimensions:) optional
    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?)

    @objc(capturer:didUpdateState:) optional
    func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.CapturerState)
}

// Intended to be a base class for video capturers
public class VideoCapturer: NSObject, @unchecked Sendable, Loggable, VideoCapturerProtocol {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<VideoCapturerDelegate>(label: "VideoCapturerDelegate")
    public let rendererDelegates = MulticastDelegate<VideoRenderer>(label: "VideoCapturerRendererDelegate")

    private let processingQueue = DispatchQueue(label: "io.livekit.videocapturer.processing", autoreleaseFrequency: .workItem)

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
    public enum CapturerState: Int, Sendable {
        case stopped
        case started
    }

    private weak var delegate: LKRTCVideoCapturerDelegate?

    let dimensionsCompleter = AsyncCompleter<Dimensions>(label: "Dimensions", defaultTimeout: .defaultCaptureStart)

    struct State {
        // Counts calls to start/stopCapturer so multiple Tracks can use the same VideoCapturer.
        var startStopCounter: Int = 0
        var dimensions: Dimensions?
        weak var processor: VideoProcessor?
        var isFrameProcessingBusy: Bool = false
    }

    let _state: StateSync<State>

    public var dimensions: Dimensions? { _state.dimensions }

    public weak var processor: VideoProcessor? {
        get { _state.processor }
        set { _state.mutate { $0.processor = newValue } }
    }

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

    init(delegate: LKRTCVideoCapturerDelegate, processor: VideoProcessor? = nil) {
        self.delegate = delegate
        _state = StateSync(State(processor: processor))
        super.init()

        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self else { return }
            if oldState.startStopCounter != newState.startStopCounter {
                log("startStopCounter \(oldState.startStopCounter) -> \(newState.startStopCounter)")
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
        _process(frame: frame,
                 capturer: capturer,
                 device: device,
                 options: options)
    }

    // Capture a CVPixelBuffer
    func capture(pixelBuffer: CVPixelBuffer,
                 capturer: LKRTCVideoCapturer,
                 timeStampNs: Int64 = VideoCapturer.createTimeStampNs(),
                 rotation: VideoRotation = ._0,
                 options: VideoCaptureOptions)
    {
        // check if pixel format is supported by WebRTC
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard VideoCapturer.supportedPixelFormats.contains(where: { $0.uint32Value == pixelFormat }) else {
            // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            // kCVPixelFormatType_32BGRA
            // kCVPixelFormatType_32ARGB
            logger.log("Skipping capture for unsupported pixel format: \(pixelFormat.toString())", .warning,
                       type: type(of: self))
            return
        }

        let sourceDimensions = Dimensions(width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
                                          height: Int32(CVPixelBufferGetHeight(pixelBuffer)))

        guard sourceDimensions.isEncodeSafe else {
            logger.log("Skipping capture for dimensions: \(sourceDimensions)", .warning,
                       type: type(of: self))
            return
        }

        let rtcBuffer = LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let rtcFrame = LKRTCVideoFrame(buffer: rtcBuffer,
                                       rotation: rotation.toRTCType(),
                                       timeStampNs: timeStampNs)

        capture(frame: rtcFrame,
                capturer: capturer,
                options: options)
    }

    // Capture a CMSampleBuffer
    func capture(sampleBuffer: CMSampleBuffer,
                 capturer: LKRTCVideoCapturer,
                 options: VideoCaptureOptions)
    {
        // Check if buffer is ready
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer)
        else {
            logger.log("Failed to capture, buffer is not ready", .warning, type: type(of: self))
            return
        }

        // attempt to determine rotation information if buffer is coming from ReplayKit
        var rotation: LKRTCVideoRotation?
        if #available(macOS 11.0, *) {
            // Check rotation tags. Extensions see these tags, but `RPScreenRecorder` does not appear to set them.
            // On iOS 12.0 and 13.0 rotation tags (other than up) are set by extensions.
            if let sampleOrientation = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil),
               let coreSampleOrientation = sampleOrientation.uint32Value
            {
                rotation = CGImagePropertyOrientation(rawValue: coreSampleOrientation)?.toRTCRotation()
            }
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.log("Failed to capture, pixel buffer not found", .warning, type: type(of: self))
            return
        }

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        capture(pixelBuffer: pixelBuffer,
                capturer: capturer,
                timeStampNs: timeStampNs,
                rotation: rotation?.toLKType() ?? ._0,
                options: options)
    }

    // Process the captured frame
    private func _process(frame: LKRTCVideoFrame,
                          capturer: LKRTCVideoCapturer,
                          device: AVCaptureDevice?,
                          options: VideoCaptureOptions)
    {
        if _state.isFrameProcessingBusy {
            log("Frame processing hasn't completed yet, skipping frame...", .warning)
            return
        }

        processingQueue.async { [weak self] in
            guard let self else { return }

            // Mark as frame processing busy.
            _state.mutate { $0.isFrameProcessingBusy = true }
            defer {
                self._state.mutate { $0.isFrameProcessingBusy = false }
            }

            var rtcFrame: LKRTCVideoFrame = frame
            guard var lkFrame: VideoFrame = frame.toLKType() else {
                log("Failed to convert a RTCVideoFrame to VideoFrame.", .error)
                return
            }

            // Apply processing if we have a processor attached.
            if let processor = _state.processor {
                guard let processedFrame = processor.process(frame: lkFrame) else {
                    log("VideoProcessor didn't return a frame, skipping frame.", .warning)
                    return
                }
                lkFrame = processedFrame
                rtcFrame = processedFrame.toRTCType()
            }

            // Resolve real dimensions (apply frame rotation)
            set(dimensions: Dimensions(width: rtcFrame.width, height: rtcFrame.height).apply(rotation: rtcFrame.rotation))

            delegate?.capturer(capturer, didCapture: rtcFrame)

            if rendererDelegates.isDelegatesNotEmpty {
                rendererDelegates.notify { [lkFrame] renderer in
                    renderer.render?(frame: lkFrame)
                    renderer.render?(frame: lkFrame, captureDevice: device, captureOptions: options)
                }
            }
        }
    }
}
