import Foundation
import WebRTC
import Promises
import ReplayKit

public class CameraCapturer: RTCCameraVideoCapturer, CaptureControllable {

    /// checks whether both front and back capturing devices exist
    public static func canTogglePosition() -> Bool {
        let devices = RTCCameraVideoCapturer.captureDevices()
        return devices.contains(where: { $0.position == .front }) &&
            devices.contains(where: { $0.position == .back })
    }

    var options: LocalVideoTrackOptions

    /// current device used for capturing
    public private(set) var device: AVCaptureDevice?

    /// current position of the device (read only)
    public var position: AVCaptureDevice.Position? {
        get {
            device?.position
        }
    }

    init(delegate: RTCVideoCapturerDelegate,
         options: LocalVideoTrackOptions = LocalVideoTrackOptions()) {

        self.options = options
        super.init(delegate: delegate)
    }

    public func toggleCameraPosition() -> Promise<Void> {
        // cannot toggle if current position is unknown
        guard position != .unspecified else {
            logger.warning("Failed to toggle camera position")
            return Promise(TrackError.invalidTrackState("Camera position unknown"))
        }

        return setCameraPosition(position == .front ? .back : .front)
    }

    public func setCameraPosition(_ position: AVCaptureDevice.Position) -> Promise<Void> {

        // update options to use new position
        options.position = position

        // restart capturer
        return stopCapture().then {
            self.startCapture()
        }
    }

    public func startCapture() -> Promise<Void> {
        let devices = RTCCameraVideoCapturer.captureDevices()
        // TODO: FaceTime Camera for macOS uses .unspecified, fall back to first device
        let device = devices.first { $0.position == options.position } ?? devices.first

        guard let device = device else {
            return Promise(TrackError.mediaError("No camera video capture devices available."))
        }

        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
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

        guard let selectedDimension = selectedDimension else {
            return Promise(TrackError.mediaError("Could not get dimensions"))
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
            return Promise(TrackError.mediaError("requested framerate is unsupported (\(minFps)-\(maxFps))"))
        }

        logger.info("starting capture with \(device), format: \(selectedFormat), fps: \(fps)")

        return Promise { resolve, reject in
            // return promise that waits for capturer to start
            self.startCapture(with: device, format: selectedFormat, fps: fps) { error in
                if let error = error {
                    logger.error("CameraCapturer failed to start \(error)")
                    reject(error)
                    return
                }

                // update internal vars
                self.device = device

                // successfully started
                resolve(())
            }
        }
    }

    public func stopCapture() -> Promise<Void> {
        return Promise { resolve, _ in
            self.stopCapture {
                // update internal vars
                self.device = nil

                // successfully stopped
                resolve(())
            }
        }
    }
}

extension LocalVideoTrack {
    
    public static func createCameraTrack(options: LocalVideoTrackOptions = LocalVideoTrackOptions(),
                                         interceptor: VideoCaptureInterceptor? = nil) -> LocalVideoTrack {
        let source: RTCVideoCapturerDelegate
        let output: RTCVideoSource
        if let interceptor = interceptor {
            source = interceptor
            output = interceptor.output
        } else {
            let videoSource = Engine.factory.videoSource()
            source = videoSource
            output = videoSource
        }

        let capturer = CameraCapturer(delegate: source, options: options)

        return LocalVideoTrack(
            capturer: capturer,
            videoSource: output,
            name: Track.cameraName,
            source: .camera
        )
    }
}
