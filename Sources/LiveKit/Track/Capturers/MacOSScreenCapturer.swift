import Foundation
import WebRTC
import ReplayKit
import Promises

// currently only used for macOS
public enum ScreenShareSource {
    case display(id: UInt32)
    case window(id: UInt32)
}

#if os(macOS)

/// Options for ``MacOSScreenCapturer``
public struct MacOSScreenCapturerOptions {
    let fps: UInt
    // let dropDuplicateFrames:
    init(fps: UInt = 24) {
        self.fps = fps
    }
}

extension ScreenShareSource {
    public static let mainDisplay: ScreenShareSource = .display(id: CGMainDisplayID())
}

extension MacOSScreenCapturer {

    public static func sources() -> [ScreenShareSource] {
        return [displayIDs().map { ScreenShareSource.display(id: $0) },
                windowIDs().map { ScreenShareSource.window(id: $0) }].flatMap { $0 }
    }

    // gets a list of window IDs
    public static func windowIDs() -> [CGWindowID] {

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,
                                               .excludeDesktopElements ], kCGNullWindowID)! as Array

        return list
            .filter { ($0.object(forKey: kCGWindowLayer) as! NSNumber).intValue == 0 }
            .map { $0.object(forKey: kCGWindowNumber) as! NSNumber }.compactMap { $0.uint32Value }
    }

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
}

public class MacOSScreenCapturer: VideoCapturer {

    private let capturer = Engine.createVideoCapturer()

    // TODO: Make it possible to change dynamically
    public var source: ScreenShareSource

    // used for display capture
    private lazy var session: AVCaptureSession = {
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: .main)
        return session
    }()

    // used for window capture
    private lazy var timer: DispatchSourceTimer = {
        let timeInterval: TimeInterval = 1 / Double(options.fps)
        let result = DispatchSource.makeTimerSource()
        result.schedule(deadline: .now() + timeInterval, repeating: timeInterval)
        result.setEventHandler(handler: { [weak self] in
            self?.onWindowCaptureTimer()
        })
        return result
    }()

    public let options: MacOSScreenCapturerOptions

    init(delegate: RTCVideoCapturerDelegate,
         source: ScreenShareSource,
         options: MacOSScreenCapturerOptions = MacOSScreenCapturerOptions()) {
        self.source = source
        self.options = options
        super.init(delegate: delegate)
    }

    private func onWindowCaptureTimer() {

        guard case .started = self.state,
              case .window(let windowId) = source else { return }

        guard let image = CGWindowListCreateImage(CGRect.null,
                                                  .optionIncludingWindow,
                                                  windowId, [.shouldBeOpaque,
                                                             .nominalResolution,
                                                             .boundsIgnoreFraming]),
              let pixelBuffer = image.toPixelBuffer() else { return }

        let systemTime = ProcessInfo.processInfo.systemUptime
        let timestampNs = UInt64(systemTime * Double(NSEC_PER_SEC))

        delegate?.capturer(capturer, didCapture: pixelBuffer, timeStampNs: timestampNs)
        // report dimensions
        self.dimensions = Dimensions(width: Int32(image.width),
                                     height: Int32(image.height))
    }

    public override func startCapture() -> Promise<Void> {
        super.startCapture().then(on: .sdk) { () -> Void in

            if case .display(let displayID) = self.source {

                // clear all previous inputs
                for input in self.session.inputs {
                    self.session.removeInput(input)
                }

                // try to create a display input
                guard let input = AVCaptureScreenInput(displayID: displayID) else {
                    // fail promise if displayID is invalid
                    throw TrackError.state(message: "Failed to create screen input with displayID: \(displayID)")
                }

                input.minFrameDuration = CMTimeMake(value: 1, timescale: Int32(self.options.fps))
                input.capturesCursor = true
                input.capturesMouseClicks = true
                self.session.addInput(input)

                self.session.startRunning()

                // report dimensions
                self.dimensions = Dimensions(width: Int32(CGDisplayPixelsWide(displayID)),
                                             height: Int32(CGDisplayPixelsHigh(displayID)))
            } else if case .window = self.source {
                self.timer.resume()
            }
        }
    }

    public override func stopCapture() -> Promise<Void> {
        super.stopCapture().then(on: .sdk) {
            if case .display = self.source {
                self.session.stopRunning()
            } else if case .window = self.source {
                self.timer.suspend()
            }
        }
    }

    deinit {
        if case .window = source {
            self.timer.cancel()
            if case .stopped = state {
                // If the timer is suspended, calling cancel without resuming
                // triggers a crash. This is documented here https://forums.developer.apple.com/thread/15902
                self.timer.resume()
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension MacOSScreenCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput, didOutput
                                sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        delegate?.capturer(capturer, didCapture: sampleBuffer)
    }
}

extension LocalVideoTrack {
    /// Creates a track that captures the whole desktop screen
    public static func createMacOSScreenShareTrack(source: ScreenShareSource = .mainDisplay) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = MacOSScreenCapturer(delegate: videoSource, source: source)
        return LocalVideoTrack(
            name: Track.screenShareName,
            source: .screenShareVideo,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}

#endif
