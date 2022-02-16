import WebRTC
import Promises

public class Track: MulticastDelegate<TrackDelegate> {

    public static let cameraName = "camera"
    public static let screenShareName = "screenshare"

    public enum Kind {
        case audio
        case video
        case none
    }

    public enum State {
        case stopped
        case started
    }

    public enum Source {
        case unknown
        case camera
        case microphone
        case screenShareVideo
        case screenShareAudio
    }

    public let kind: Track.Kind
    public let source: Track.Source
    public internal(set) var name: String
    public internal(set) var sid: Sid?
    public let mediaTrack: RTCMediaStreamTrack
    public private(set) var muted: Bool = false
    public internal(set) var transceiver: RTCRtpTransceiver?
    public var sender: RTCRtpSender? {
        return transceiver?.sender
    }

    public private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            didUpdateState()
        }
    }

    init(name: String, kind: Kind, source: Source, track: RTCMediaStreamTrack) {
        self.name = name
        self.kind = kind
        self.source = source
        mediaTrack = track
    }

    // will fail if already started (to prevent duplicate code execution)
    internal func start() -> Promise<Void> {
        guard state != .started else {
            return Promise(TrackError.state(message: "Already started"))
        }

        self.state = .started
        return Promise(())
    }

    // will fail if already stopped (to prevent duplicate code execution)
    public func stop() -> Promise<Void> {
        guard state != .stopped else {
            return Promise(TrackError.state(message: "Already stopped"))
        }

        self.state = .stopped
        return Promise(())
    }

    internal func enable() -> Promise<Void> {
        Promise(on: .sdk) {
            self.mediaTrack.isEnabled = true
        }
    }

    internal func disable() -> Promise<Void> {
        Promise(on: .sdk) {
            self.mediaTrack.isEnabled = false
        }
    }

    internal func didUpdateState() {
        //
    }

    internal func set(muted: Bool,
                      shouldNotify: Bool = true,
                      shouldSendSignal: Bool = false) {

        guard muted != self.muted else { return }
        self.muted = muted

        if shouldNotify {
            notify { $0.track(self, didUpdate: muted, shouldSendSignal: shouldSendSignal) }
        }
    }
}
