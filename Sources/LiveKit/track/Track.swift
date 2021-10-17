import Foundation
import WebRTC

public class Track {

    public enum Kind {
        case audio
        case video
        case none
    }

    public enum State {
        case stopped
        case started
    }

    public internal(set) var name: String
    public internal(set) var sid: Sid?
    public internal(set) var kind: Track.Kind
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

    init(name: String, kind: Kind, track: RTCMediaStreamTrack) {
        self.name = name
        self.kind = kind
        mediaTrack = track
    }

    internal func start() {
        state = .started
    }

    internal func stop() {
        state = .stopped
    }

    internal func stateUpdated() {
        if .stopped == state {
            mediaTrack.isEnabled = false
        }
    }
}
