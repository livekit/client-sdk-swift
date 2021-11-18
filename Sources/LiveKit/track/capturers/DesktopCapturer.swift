import Foundation
import WebRTC
import ReplayKit
import Promises

#if os(macOS)

/// Options for ``DesktopCapturer``
struct DesktopCapturerOptions {
    //
}

class DesktopCapturer: VideoCapturer, AVCaptureVideoDataOutputSampleBufferDelegate {

    func add(delegate: VideoCapturerDelegate) {
        delegates.add(delegate: delegate)
    }

    func remove(delegate: VideoCapturerDelegate) {
        delegates.remove(delegate: delegate)
    }

    // currently, only main display
    private let displayId = CGMainDisplayID()
    private let session: AVCaptureSession
    private let input: AVCaptureScreenInput?
    private let output: AVCaptureVideoDataOutput
    private let delegates = MulticastDelegate<VideoCapturerDelegate>()

    public var dimensions: Dimensions? {
        get {
            Dimensions(width: Int32(CGDisplayPixelsWide(displayId)),
                       height: Int32(CGDisplayPixelsHigh(displayId)))

        }
    }

    override init(delegate: RTCVideoCapturerDelegate) {
        session = AVCaptureSession()
        input = AVCaptureScreenInput(displayID: displayId)
        output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        super.init(delegate: delegate)
        output.setSampleBufferDelegate(self, queue: .main)

        // add I/O
        if let input = input {
            input.capturesCursor = true
            input.capturesMouseClicks = true
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

extension LocalVideoTrack {
    /// Creates a track that captures the whole desktop screen
    public static func createDesktopTrack() -> LocalVideoTrack {
        let videoSource = Engine.factory.videoSource()
        let capturer = DesktopCapturer(delegate: videoSource)
        return LocalVideoTrack(
            capturer: capturer,
            videoSource: videoSource,
            name: Track.screenShareName,
            source: .screenShareVideo
        )
    }
}

#endif
