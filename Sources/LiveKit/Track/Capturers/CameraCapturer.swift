import Foundation
import WebRTC
import Promises
import ReplayKit
import OrderedCollections

public class CameraCapturer: VideoCapturer {

    private let capturer: RTCCameraVideoCapturer

    public static func captureDevices() -> [AVCaptureDevice] {
        DispatchQueue.webRTC.sync { RTCCameraVideoCapturer.captureDevices() }
    }

    /// Checks whether both front and back capturing devices exist, and can be switched.
    public static func canSwitchPosition() -> Bool {
        let devices = captureDevices()
        return devices.contains(where: { $0.position == .front }) &&
            devices.contains(where: { $0.position == .back })
    }

    /// Current device used for capturing
    public private(set) var device: AVCaptureDevice?

    /// Current position of the device
    public var position: AVCaptureDevice.Position? {
        get { device?.position }
    }

    public var options: CameraCaptureOptions

    init(delegate: RTCVideoCapturerDelegate, options: CameraCaptureOptions) {
        self.capturer = DispatchQueue.webRTC.sync { RTCCameraVideoCapturer(delegate: delegate) }
        self.options = options
        super.init(delegate: delegate)
    }

    /// Switches the camera position between `.front` and `.back` if supported by the device.
    @discardableResult
    public func switchCameraPosition() -> Promise<Void> {
        // cannot toggle if current position is unknown
        guard position != .unspecified else {
            log("Failed to toggle camera position", .warning)
            return Promise(TrackError.state(message: "Camera position unknown"))
        }

        return setCameraPosition(position == .front ? .back : .front)
    }

    /// Sets the camera's position to `.front` or `.back` when supported
    public func setCameraPosition(_ position: AVCaptureDevice.Position) -> Promise<Void> {

        log("setCameraPosition(position: \(position)")

        // update options to use new position
        options = options.copyWith(position: position)

        // restart capturer
        return restartCapture()
    }

    public override func startCapture() -> Promise<Void> {

        let preferredPixelFormat = capturer.preferredOutputPixelFormat()
        log("CameraCapturer.preferredPixelFormat: \(preferredPixelFormat.toString())")

        let devices = CameraCapturer.captureDevices()
        // TODO: FaceTime Camera for macOS uses .unspecified, fall back to first device

        guard let device = devices.first(where: { $0.position == options.position }) ?? devices.first else {
            log("No camera video capture devices available", .error)
            return Promise(TrackError.capturer(message: "No camera video capture devices available"))
        }

        // list of all formats in order of dimensions size
        let formats = DispatchQueue.webRTC.sync { RTCCameraVideoCapturer.supportedFormats(for: device) }
        // create a dictionary sorted by dimensions size
        let sortedFormats = OrderedDictionary(uniqueKeysWithValues: formats.map { ($0, CMVideoFormatDescriptionGetDimensions($0.formatDescription)) })
            .sorted { $0.value.area < $1.value.area }

        // default to the smallest
        var selectedFormat = sortedFormats.first

        // find preferred capture format if specified in options
        if let preferredFormat = options.preferredFormat,
           let foundFormat = sortedFormats.first(where: { $0.key == preferredFormat }) {
            selectedFormat = foundFormat
        } else {
            log("formats: \(sortedFormats.map { String(describing: $0.value) }), target: \(options.dimensions)")
            // find format that satisfies preferred dimensions
            selectedFormat = sortedFormats.first(where: { $0.value.area >= options.dimensions.area })
        }

        // format should be resolved at this point
        guard let selectedFormat = selectedFormat else {
            log("Unable to resolve format", .error)
            return Promise(TrackError.capturer(message: "Unable to determine format for camera capturer"))
        }

        // ensure fps is within range
        let fpsRange = selectedFormat.key.videoSupportedFrameRateRanges
            .reduce((min: Int.max, max: 0)) { (min($0.min, Int($1.minFrameRate)), max($0.max, Int($1.maxFrameRate)) ) }
        log("fpsRange: \(fpsRange)")

        guard options.fps >= fpsRange.min && options.fps <= fpsRange.max else {
            return Promise(TrackError.capturer(message: "Requested framerate is out of range (\(fpsRange)"))
        }

        log("Starting camera capturer device: \(device), format: \(selectedFormat), fps: \(options.fps)", .info)

        // adapt if requested dimensions and camera's dimensions don't match
        if let videoSource = delegate as? RTCVideoSource,
           selectedFormat.value != options.dimensions {

            self.log("adapting to: \(options.dimensions) fps: \(options.fps)")
            videoSource.adaptOutputFormat(toWidth: options.dimensions.width,
                                          height: options.dimensions.height,
                                          fps: Int32(options.fps))
        }

        return super.startCapture().then(on: .sdk) {
            // return promise that waits for capturer to start
            Promise(on: .webRTC) { resolve, fail in
                self.capturer.startCapture(with: device, format: selectedFormat.key, fps: self.options.fps) { error in
                    if let error = error {
                        self.log("CameraCapturer failed to start \(error)", .error)
                        fail(error)
                        return
                    }

                    // update internal vars
                    self.device = device
                    // this will trigger to re-compute encodings for sender parameters if dimensions have updated
                    self.dimensions = selectedFormat.value

                    // successfully started
                    resolve(())
                }
            }
        }
    }

    public override func stopCapture() -> Promise<Void> {
        return super.stopCapture().then(on: .sdk) {
            Promise(on: .webRTC) { resolve, _ in
                self.capturer.stopCapture {
                    // update internal vars
                    self.device = nil
                    self.dimensions = nil

                    // successfully stopped
                    resolve(())
                }
            }
        }
    }
}

extension LocalVideoTrack {

    public static func createCameraTrack(options: CameraCaptureOptions = CameraCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: false)
        let capturer = CameraCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(
            name: Track.cameraName,
            source: .camera,
            capturer: capturer,
            videoSource: videoSource
        )
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
