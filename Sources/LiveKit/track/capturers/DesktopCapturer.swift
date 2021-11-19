import Foundation
import WebRTC
import ReplayKit
import Promises

#if os(macOS)

/// Options for ``DesktopCapturer``
struct DesktopCapturerOptions {
    //
}

public class DesktopCapturer: VideoCapturer, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let capturer = RTCVideoCapturer()

    // currently, only main display
    private let displayId = CGMainDisplayID()
    private let session: AVCaptureSession
    private let input: AVCaptureScreenInput?
    private let output: AVCaptureVideoDataOutput

    // gets a list of display IDs
    public static func displayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        var activeCount: UInt32 = 0

        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
            return []
        }

        var displayIDList = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &(displayIDList), &activeCount) == .success else {
            return []
        }

        return displayIDList
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

    public override func startCapture() -> Promise<Void> {
        super.startCapture().then {
            self.dimensions = Dimensions(width: Int32(CGDisplayPixelsWide(self.displayId)),
                                         height: Int32(CGDisplayPixelsHigh(self.displayId)))

            self.session.startRunning()
        }
    }

    public override func stopCapture() -> Promise<Void> {
        super.stopCapture().then {
            self.session.stopRunning()
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput, didOutput
                                sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        logger.debug("\(self) captured sample buffer")
        delegate?.capturer(capturer, didCapture: sampleBuffer)
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
