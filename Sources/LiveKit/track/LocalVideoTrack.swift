import WebRTC
import Promises
import ReplayKit
import Foundation

public protocol CaptureControllable {
    func startCapture() -> Promise<Void>
    func stopCapture() -> Promise<Void>
}

public typealias VideoCapturer = RTCVideoCapturer & CaptureControllable

class BufferCapturer: VideoCapturer {

    func startCapture() -> Promise<Void> {
        // nothing to do for now
        Promise(())
    }

    func stopCapture() -> Promise<Void> {
        // nothing to do for now
        Promise(())
    }

    func capture(_ sampleBuffer: CMSampleBuffer) {
        delegate?.capturer(self, didCapture: sampleBuffer)
    }
}

#if os(macOS)
class DesktopScreenCapturer: VideoCapturer, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session: AVCaptureSession
    let input: AVCaptureScreenInput?
    let output: AVCaptureVideoDataOutput

    override init(delegate: RTCVideoCapturerDelegate) {
        session = AVCaptureSession()
        input = AVCaptureScreenInput(displayID: CGMainDisplayID())
        output = AVCaptureVideoDataOutput()
        super.init(delegate: delegate)
        output.setSampleBufferDelegate(self, queue: .main)

        // add I/O
        if let input = input {
            session.addInput(input)
        }
        session.addOutput(output)
    }

    func startCapture() -> Promise<Void> {
        return Promise { () -> Void in
            self.session.startRunning()
        }
    }

    func stopCapture() -> Promise<Void> {
        return Promise { () -> Void in
            self.session.stopRunning()
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput
                        sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        logger.debug("\(self) captured sample buffer")
        self.delegate?.capturer(self, didCapture: sampleBuffer)
    }
}
#endif

@available(macOS 11.0, iOS 11.0, *)
class InAppScreenCapturer: VideoCapturer {

    func startCapture() -> Promise<Void> {
        return Promise { resolve, reject in
            RPScreenRecorder.shared().startCapture { sampleBuffer, type, _ in
                if type == .video {
                    self.delegate?.capturer(self, didCapture: sampleBuffer)
                }
            } completionHandler: { error in
                if let error = error {
                    reject(error)
                    return
                }
                resolve(())
            }
        }
    }

    func stopCapture() -> Promise<Void> {
        return Promise { resolve, reject in
            RPScreenRecorder.shared().stopCapture { error in
                if let error = error {
                    reject(error)
                    return
                }
                resolve(())
            }

        }
    }
}

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

public class LocalVideoTrack: VideoTrack {

    public internal(set) var capturer: VideoCapturer
    public internal(set) var videoSource: RTCVideoSource

    // used to calculate RTCRtpEncoding, may not be always available
    // depending on capturer type
    public internal(set) var dimensions: Dimensions?

    init(capturer: VideoCapturer,
         videoSource: RTCVideoSource,
         name: String,
         source: Track.Source,
         dimensions: Dimensions? = nil) {

        let rtcTrack = Engine.factory.videoTrack(with: videoSource, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true

        self.capturer = capturer
        self.videoSource = videoSource
        self.dimensions = dimensions
        super.init(rtcTrack: rtcTrack, name: name, source: source)
    }

    public func restartTrack(options: LocalVideoTrackOptions = LocalVideoTrackOptions()) {

        //        let result = LocalVideoTrack.createCameraCapturer(options: options)
        //
        //        // Stop previous capturer
        //        if let capturer = capturer as? RTCCameraVideoCapturer {
        //            capturer.stopCapture()
        //        }
        //
        //        //        self.capturer = result.capturer
        //        self.videoSource = result.videoSource
        //
        //        // create a new RTCVideoTrack
        //        let rtcTrack = Engine.factory.videoTrack(with: result.videoSource, trackId: UUID().uuidString)
        //        rtcTrack.isEnabled = true
        //
        //        // TODO: Stop previous mediaTrack
        //        mediaTrack.isEnabled = false
        //        mediaTrack = rtcTrack
        //
        //        // Set the new track
        //        sender?.track = rtcTrack
    }

    @discardableResult
    public override func start() -> Promise<Void> {
        super.start().then {
            self.capturer.startCapture()
        }
    }

    @discardableResult
    public override func stop() -> Promise<Void> {
        super.stop().then {
            self.capturer.stopCapture()
        }
    }

    // MARK: - High level methods

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

    /// Creates a track that captures in-app screen only (due to limitation of ReplayKit)
    @available(macOS 11.0, iOS 11.0, *)
    public static func createInAppScreenShareTrack() -> LocalVideoTrack {
        let videoSource = Engine.factory.videoSource()
        let capturer = InAppScreenCapturer(delegate: videoSource)
        return LocalVideoTrack(
            capturer: capturer,
            videoSource: videoSource,
            name: Track.screenShareName,
            source: .screenShareVideo
        )
    }

    /// Creates a track that captures the whole desktop screen
    #if os(macOS)
    public static func createDesktopScreenShareTrack() -> LocalVideoTrack {
        let videoSource = Engine.factory.videoSource()
        let capturer = DesktopScreenCapturer(delegate: videoSource)
        return LocalVideoTrack(
            capturer: capturer,
            videoSource: videoSource,
            name: Track.screenShareName,
            source: .screenShareVideo
        )
    }
    #endif

    /// Creates a track that can directly capture `CVPixelBuffer` or `CMSampleBuffer` for convienience
    public static func createBufferTrack(name: String = Track.screenShareName,
                                         source: VideoTrack.Source = .screenShareVideo) -> LocalVideoTrack {
        let videoSource = Engine.factory.videoSource()
        let capturer = BufferCapturer(delegate: videoSource)
        return LocalVideoTrack(
            capturer: capturer,
            videoSource: videoSource,
            name: name,
            source: source
        )
    }
}
