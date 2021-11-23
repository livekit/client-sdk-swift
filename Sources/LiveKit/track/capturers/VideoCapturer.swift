import WebRTC
import Promises

public protocol VideoCapturerProtocol {
    var capturer: RTCVideoCapturer { get }
}

extension VideoCapturerProtocol {
    public var capturer: RTCVideoCapturer {
        get { fatalError("Must be implemented") }
    }
}

public protocol VideoCapturerDelegate {
    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?)
}

// Intended to be a base class for video capturers
public class VideoCapturer: MulticastDelegate<VideoCapturerDelegate>, VideoCapturerProtocol {

    public enum State {
        case stopped
        case started
    }

    internal weak var delegate: RTCVideoCapturerDelegate?

    public internal(set) var dimensions: Dimensions? {
        didSet {
            guard oldValue != dimensions else { return }
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
            return Promise(TrackError.invalidTrackState("Already started"))
        }

        self.state = .started
        return Promise(())
    }

    // will fail if already stopped (to prevent duplicate code execution)
    public func stopCapture() -> Promise<Void> {
        guard state != .stopped else {
            return Promise(TrackError.invalidTrackState("Already stopped"))
        }

        self.state = .stopped
        return Promise(())
    }

    public func restartCapture() -> Promise<Void> {
        stopCapture().recover { _ in
            logger.warning("Capturer was already stopped")
        }.then {
            self.startCapture()
        }
    }
}
