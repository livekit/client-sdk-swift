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

    internal var delegate: RTCVideoCapturerDelegate

    public internal(set) var dimensions: Dimensions? {
        didSet {
            guard oldValue != dimensions else { return }
            notify { $0.capturer(self, didUpdate: self.dimensions) }
        }
    }

    init(delegate: RTCVideoCapturerDelegate) {
        self.delegate = delegate
    }

    func startCapture() -> Promise<Void> {
        Promise(())
    }

    func stopCapture() -> Promise<Void> {
        Promise(())
    }
}
