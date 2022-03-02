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
    static let supportedPixelFormats = DispatchQueue.webRTC.sync { RTCCVPixelBuffer.supportedPixelFormats() }

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
        guard state != .started else {
            log("Capturer already started", .warning)
            return Promise(TrackError.state(message: "Already started"))
        }

        self.state = .started
        return Promise(())
    }

    // will fail if already stopped (to prevent duplicate code execution)
    public func stopCapture() -> Promise<Void> {
        guard state != .stopped else {
            log("Capturer already stopped", .warning)
            return Promise(TrackError.state(message: "Already stopped"))
        }

        self.state = .stopped
        return Promise(())
    }

    public func restartCapture() -> Promise<Void> {
        stopCapture().recover { _ in
            self.log("Capturer was already stopped", .warning)
        }.then(on: .sdk) {
            self.startCapture()
        }
    }
}
