import WebRTC
import Promises

public class Track: MulticastDelegate<TrackDelegate> {

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
    public internal(set) var mediaTrack: RTCMediaStreamTrack
    public internal(set) var transceiver: RTCRtpTransceiver?
    public var sender: RTCRtpSender? {
        return transceiver?.sender
    }

    public private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            stateUpdated()
        }
    }

    init(name: String, kind: Kind, source: Source, track: RTCMediaStreamTrack) {
        self.name = name
        self.kind = kind
        self.source = source
        mediaTrack = track
    }

    @discardableResult
    internal func start() -> Promise<Void> {
        Promise<Void> {
            self.state = .started
        }
    }

    @discardableResult
    public func stop() -> Promise<Void> {
        Promise<Void> {
            self.state = .stopped
        }
    }

    internal func enable() {
        mediaTrack.isEnabled = true
    }

    internal func disable() {
        mediaTrack.isEnabled = false
    }

    internal func stateUpdated() {
        if .stopped == state {
            mediaTrack.isEnabled = false
        }
    }
}
