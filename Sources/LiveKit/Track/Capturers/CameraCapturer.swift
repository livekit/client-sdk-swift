import Foundation
import WebRTC
import Promises
import ReplayKit

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

    /// The ``LocalAudioTrackOptions`` used for this capturer.
    /// It is possible to modify the options but `restartCapture` must be called.
    public var options: VideoCaptureOptions

    /// Current device used for capturing
    public private(set) var device: AVCaptureDevice?

    /// Current position of the device
    public var position: AVCaptureDevice.Position? {
        get { device?.position }
    }

    init(delegate: RTCVideoCapturerDelegate,
         options: VideoCaptureOptions? = nil) {
        self.capturer = DispatchQueue.webRTC.sync { RTCCameraVideoCapturer(delegate: delegate) }
        self.options = options ?? VideoCaptureOptions()
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
        options.position = position

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

        let formats = DispatchQueue.webRTC.sync { RTCCameraVideoCapturer.supportedFormats(for: device) }
        log("CameraCapturer.supportedFormats: \(formats)")

        let (targetWidth, targetHeight) = (options.captureParameter.dimensions.width,
                                           options.captureParameter.dimensions.height)

        var currentDiff = Int32.max
        var selectedFormat: AVCaptureDevice.Format = formats[0]
        var selectedDimension: Dimensions?
        for format in formats {
            if options.captureFormat == format {
                selectedFormat = format
                break
            }
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let diff = abs(targetWidth - dimension.width) + abs(targetHeight - dimension.height)
            if diff < currentDiff {
                selectedFormat = format
                currentDiff = diff
                selectedDimension = dimension
            }
        }

        guard selectedDimension != nil else {
            log("Could not get dimensions", .error)
            return Promise(TrackError.capturer(message: "Could not get dimensions"))
        }

        let fps = options.captureParameter.encoding.maxFps

        // discover FPS limits
        var minFps = 60
        var maxFps = 0
        for fpsRange in selectedFormat.videoSupportedFrameRateRanges {
            minFps = min(minFps, Int(fpsRange.minFrameRate))
            maxFps = max(maxFps, Int(fpsRange.maxFrameRate))
        }
        if fps < minFps || fps > maxFps {
            return Promise(TrackError.capturer(message: "requested framerate is unsupported (\(minFps)-\(maxFps))"))
        }

        log("Starting camera capturer device: \(device), format: \(selectedFormat), fps: \(fps)", .info)

        return super.startCapture().then(on: .sdk) {
            // return promise that waits for capturer to start
            Promise(on: .webRTC) { resolve, fail in
                self.capturer.startCapture(with: device, format: selectedFormat, fps: fps) { error in
                    if let error = error {
                        self.log("CameraCapturer failed to start \(error)", .error)
                        fail(error)
                        return
                    }

                    // update internal vars
                    self.device = device
                    // this will trigger to re-compute encodings for sender parameters if dimensions have updated
                    self.dimensions = selectedDimension

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

    public static func createCameraTrack(options: VideoCaptureOptions? = nil,
                                         interceptor: VideoCaptureInterceptor? = nil) -> LocalVideoTrack {
        let source: RTCVideoCapturerDelegate
        let output: RTCVideoSource
        if let interceptor = interceptor {
            source = interceptor
            output = interceptor.output
        } else {
            let videoSource = Engine.createVideoSource(forScreenShare: false)
            source = videoSource
            output = videoSource
        }

        let capturer = CameraCapturer(delegate: source, options: options)

        return LocalVideoTrack(
            name: Track.cameraName,
            source: .camera,
            capturer: capturer,
            videoSource: output
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
