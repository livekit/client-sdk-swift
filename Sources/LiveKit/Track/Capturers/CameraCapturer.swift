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

@_implementationOnly import WebRTC

public class CameraCapturer: VideoCapturer {
    @objc
    public static func captureDevices() -> [AVCaptureDevice] {
        DispatchQueue.liveKitWebRTC.sync { LKRTCCameraVideoCapturer.captureDevices() }
    }

    /// Checks whether both front and back capturing devices exist, and can be switched.
    @objc
    public static func canSwitchPosition() -> Bool {
        let devices = captureDevices()
        return devices.contains(where: { $0.position == .front }) &&
            devices.contains(where: { $0.position == .back })
    }

    /// Current device used for capturing
    @objc
    public private(set) var device: AVCaptureDevice?

    /// Current position of the device
    public var position: AVCaptureDevice.Position? {
        device?.position
    }

    @objc
    public var options: CameraCaptureOptions

    public var isMultitaskingAccessSupported: Bool {
        #if os(iOS) || os(tvOS)
            if #available(iOS 16, *, tvOS 17, *) {
                self.capturer.captureSession.beginConfiguration()
                defer { self.capturer.captureSession.commitConfiguration() }
                return self.capturer.captureSession.isMultitaskingCameraAccessSupported
            }
        #endif
        return false
    }

    public var isMultitaskingAccessEnabled: Bool {
        get {
            #if os(iOS) || os(tvOS)
                if #available(iOS 16, *, tvOS 17, *) {
                    return self.capturer.captureSession.isMultitaskingCameraAccessEnabled
                }
            #endif
            return false
        }
        set {
            #if os(iOS) || os(tvOS)
                if #available(iOS 16, *, tvOS 17, *) {
                    self.capturer.captureSession.isMultitaskingCameraAccessEnabled = newValue
                }
            #endif
        }
    }

    // Used to hide LKRTCVideoCapturerDelegate symbol
    private lazy var adapter: VideoCapturerDelegateAdapter = .init(cameraCapturer: self)

    // RTCCameraVideoCapturer used internally for now
    private lazy var capturer: LKRTCCameraVideoCapturer = DispatchQueue.liveKitWebRTC.sync { LKRTCCameraVideoCapturer(delegate: adapter) }

    init(delegate: LKRTCVideoCapturerDelegate, options: CameraCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)

        log("isMultitaskingAccessSupported: \(isMultitaskingAccessSupported)", .info)
    }

    /// Switches the camera position between `.front` and `.back` if supported by the device.
    @objc
    @discardableResult
    public func switchCameraPosition() async throws -> Bool {
        // Cannot toggle if current position is unknown
        guard position != .unspecified else {
            log("Failed to toggle camera position", .error)
            throw LiveKitError(.invalidState, message: "Failed to toggle camera position")
        }

        return try await set(cameraPosition: position == .front ? .back : .front)
    }

    /// Sets the camera's position to `.front` or `.back` when supported
    @objc
    @discardableResult
    public func set(cameraPosition position: AVCaptureDevice.Position) async throws -> Bool {
        log("set(cameraPosition:) \(position)")

        // update options to use new position
        options = options.copyWith(position: position)

        // Restart capturer
        return try await restartCapture()
    }

    override public func startCapture() async throws -> Bool {
        let didStart = try await super.startCapture()

        // Already started
        guard didStart else { return false }

        let preferredPixelFormat = capturer.preferredOutputPixelFormat()
        log("CameraCapturer.preferredPixelFormat: \(preferredPixelFormat.toString())")

        let devices = CameraCapturer.captureDevices()
        // TODO: FaceTime Camera for macOS uses .unspecified, fall back to first device

        guard let device = devices.first(where: { $0.position == self.options.position }) ?? devices.first else {
            log("No camera video capture devices available", .error)
            throw LiveKitError(.deviceNotFound, message: "No camera video capture devices available")
        }

        // list of all formats in order of dimensions size
        let formats = DispatchQueue.liveKitWebRTC.sync { LKRTCCameraVideoCapturer.supportedFormats(for: device) }
        // create an array of sorted touples by dimensions size
        let sortedFormats = formats.map { (format: $0, dimensions: Dimensions(from: CMVideoFormatDescriptionGetDimensions($0.formatDescription))) }
            .sorted { $0.dimensions.area < $1.dimensions.area }

        log("sortedFormats: \(sortedFormats.map { "(dimensions: \(String(describing: $0.dimensions)), fps: \(String(describing: $0.format.fpsRange())))" }), target dimensions: \(options.dimensions)")

        // default to the largest supported dimensions (backup)
        var selectedFormat = sortedFormats.last

        if let preferredFormat = options.preferredFormat,
           let foundFormat = sortedFormats.first(where: { $0.format == preferredFormat })
        {
            // Use the preferred capture format if specified in options
            selectedFormat = foundFormat
        } else {
            if let foundFormat = sortedFormats.first(where: { $0.dimensions.area >= self.options.dimensions.area && $0.format.fpsRange().contains(self.options.fps) }) {
                // Use the first format that satisfies preferred dimensions & fps
                selectedFormat = foundFormat
            } else if let foundFormat = sortedFormats.first(where: { $0.dimensions.area >= self.options.dimensions.area }) {
                // Use the first format that satisfies preferred dimensions (without fps)
                selectedFormat = foundFormat
            }
        }

        // format should be resolved at this point
        guard let selectedFormat else {
            log("Unable to resolve capture format", .error)
            throw LiveKitError(.captureFormatNotFound, message: "Unable to resolve capture format")
        }

        let fpsRange = selectedFormat.format.fpsRange()

        // this should never happen
        guard fpsRange != 0 ... 0 else {
            log("Unable to determine supported fps range for format: \(selectedFormat)", .error)
            throw LiveKitError(.unableToResolveFPSRange, message: "Unable to determine supported fps range for format: \(selectedFormat)")
        }

        // default to fps in options
        var selectedFps = options.fps

        if !fpsRange.contains(selectedFps) {
            // log a warning, but continue
            log("requested fps: \(options.fps) is out of range: \(fpsRange) and will be clamped", .warning)
            // clamp to supported fps range
            selectedFps = selectedFps.clamped(to: fpsRange)
        }

        log("starting camera capturer device: \(device), format: \(selectedFormat), fps: \(selectedFps)(\(fpsRange))", .info)

        // adapt if requested dimensions and camera's dimensions don't match
        if let videoSource = delegate as? LKRTCVideoSource,
           selectedFormat.dimensions != self.options.dimensions
        {
            // self.log("adaptOutputFormat to: \(options.dimensions) fps: \(self.options.fps)")
            videoSource.adaptOutputFormat(toWidth: options.dimensions.width,
                                          height: options.dimensions.height,
                                          fps: Int32(options.fps))
        }

        try await capturer.startCapture(with: device, format: selectedFormat.format, fps: selectedFps)

        // Update internal vars
        self.device = device

        return true
    }

    override public func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }

        await capturer.stopCapture()

        // Update internal vars
        device = nil
        dimensions = nil

        return true
    }
}

class VideoCapturerDelegateAdapter: NSObject, LKRTCVideoCapturerDelegate {
    weak var cameraCapturer: CameraCapturer?

    init(cameraCapturer: CameraCapturer? = nil) {
        self.cameraCapturer = cameraCapturer
    }

    func capturer(_ capturer: LKRTCVideoCapturer, didCapture frame: LKRTCVideoFrame) {
        guard let cameraCapturer else { return }
        // Resolve real dimensions (apply frame rotation)
        cameraCapturer.dimensions = Dimensions(width: frame.width, height: frame.height).apply(rotation: frame.rotation)
        // Pass frame to video source
        cameraCapturer.delegate?.capturer(capturer, didCapture: frame)
    }
}

public extension LocalVideoTrack {
    @objc
    static func createCameraTrack() -> LocalVideoTrack {
        createCameraTrack(name: nil, options: nil)
    }

    @objc
    static func createCameraTrack(name: String? = nil,
                                  options: CameraCaptureOptions? = nil,
                                  reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = Engine.createVideoSource(forScreenShare: false)
        let capturer = CameraCapturer(delegate: videoSource, options: options ?? CameraCaptureOptions())
        return LocalVideoTrack(name: name ?? Track.cameraName,
                               source: .camera,
                               capturer: capturer,
                               videoSource: videoSource,
                               reportStatistics: reportStatistics)
    }
}

extension AVCaptureDevice.Position: CustomStringConvertible {
    public var description: String {
        switch self {
        case .front: return ".front"
        case .back: return ".back"
        case .unspecified: return ".unspecified"
        default: return "unknown"
        }
    }
}

extension Comparable {
    // clamp a value within the range
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension AVFrameRateRange {
    // convert to a ClosedRange
    func toRange() -> ClosedRange<Int> {
        Int(minFrameRate) ... Int(maxFrameRate)
    }
}

extension AVCaptureDevice.Format {
    // computes a ClosedRange of supported FPSs for this format
    func fpsRange() -> ClosedRange<Int> {
        videoSupportedFrameRateRanges.map { $0.toRange() }.reduce(into: 0 ... 0) { result, current in
            result = merge(range: result, with: current)
        }
    }
}
