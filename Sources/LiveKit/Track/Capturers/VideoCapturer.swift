import WebRTC
import Promises

public protocol VideoCapturerProtocol {
    var capturer: RTCVideoCapturer { get }
}

extension VideoCapturerProtocol {

    public var capturer: RTCVideoCapturer {
        fatalError("Must be implemented")
    }
}

public protocol VideoCapturerDelegate: AnyObject {
    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?)
    func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.State)
}

public extension VideoCapturerDelegate {
    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?) {}
    func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.State) {}
}

// MARK: - Closures

class VideoCapturerDelegateClosures: NSObject, VideoCapturerDelegate, Loggable {

    typealias DidUpdateDimensions = (VideoCapturer, Dimensions?) -> Void

    let didUpdateDimensions: DidUpdateDimensions?

    init(didUpdateDimensions: DidUpdateDimensions? = nil) {
        self.didUpdateDimensions = didUpdateDimensions
        super.init()
        log()
    }

    deinit {
        log()
    }

    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?) {
        didUpdateDimensions?(capturer, dimensions)
    }
}

internal extension VideoCapturer {

    func waitForDimensions(allowCurrent: Bool = true) -> WaitPromises<Void> {

        if allowCurrent, dimensions != nil {
            return (Promise(()), Promise(()))
        }

        let listen = Promise<Void>.pending()
        let wait = Promise<Void>(on: .sdk) { resolve, _ in
            // create temporary delegate
            var delegate: VideoCapturerDelegateClosures?
            delegate = VideoCapturerDelegateClosures(didUpdateDimensions: { _, _ in
                // wait until connected
                resolve(())
                self.log("Dimensions resolved...")
                delegate = nil
            })
            // not required to clean up since weak reference
            self.add(delegate: delegate!)
            self.log("Waiting for dimensions...")
            listen.fulfill(())
        }
        // convert to a timed-promise
        .timeout(.captureStart)

        return (listen, wait)
    }
}

// Intended to be a base class for video capturers
public class VideoCapturer: MulticastDelegate<VideoCapturerDelegate>, VideoCapturerProtocol {

    /// Array of supported pixel formats that can be used to capture a frame.
    ///
    /// Usually the following formats are supported but it is recommended to confirm at run-time:
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`,
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`,
    /// `kCVPixelFormatType_32BGRA`,
    /// `kCVPixelFormatType_32ARGB`.
    public static let supportedPixelFormats = DispatchQueue.webRTC.sync { RTCCVPixelBuffer.supportedPixelFormats() }

    public enum State {
        case stopped
        case started
    }

    internal weak var delegate: RTCVideoCapturerDelegate?

    public internal(set) var dimensions: Dimensions? {
        didSet {
            guard oldValue != dimensions else { return }
            log("\(String(describing: oldValue)) -> \(String(describing: dimensions))")
            notify { $0.capturer(self, didUpdate: self.dimensions) }
        }
    }

    public private(set) var state: State = .stopped

    init(delegate: RTCVideoCapturerDelegate) {
        self.delegate = delegate
    }

    // will fail if already started (to prevent duplicate code execution)
    public func startCapture() -> Promise<Void> {

        Promise(on: .sdk) { () -> Void in

            guard self.state != .started else {
                self.log("Capturer already started", .warning)
                throw TrackError.state(message: "Already started")
            }

            self.state = .started
            self.notify { $0.capturer(self, didUpdate: .started) }
        }
    }

    // will fail if already stopped (to prevent duplicate code execution)
    public func stopCapture() -> Promise<Void> {

        Promise(on: .sdk) { () -> Void in

            guard self.state != .stopped else {
                self.log("Capturer already stopped", .warning)
                throw TrackError.state(message: "Already stopped")
            }

            self.state = .stopped
            self.notify { $0.capturer(self, didUpdate: .stopped) }
        }
    }

    public func restartCapture() -> Promise<Void> {
        stopCapture().recover { _ in
            self.log("Capturer was already stopped", .warning)
        }.then(on: .sdk) {
            self.startCapture()
        }
    }
}
