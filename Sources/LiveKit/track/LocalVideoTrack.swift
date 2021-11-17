import Foundation
import WebRTC
import Promises
import ReplayKit

public protocol CaptureControllable {
    func startCapture() -> Promise<Void>
    func stopCapture() -> Promise<Void>
}

public typealias VideoCapturer = RTCVideoCapturer & CaptureControllable

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
