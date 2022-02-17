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
    public internal(set) var stats: TrackStats?
    public var sender: RTCRtpSender? {
        return transceiver?.sender
    }

    /// Dimensions of the video (only if video track)
    public private(set) var dimensions: Dimensions?
    /// The last video frame received for this track
    public private(set) var videoFrame: RTCVideoFrame?

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

        if let videoTrack = mediaTrack as? RTCVideoTrack {
            DispatchQueue.webRTC.sync { videoTrack.add(self) }
        }

        self.state = .started
        return Promise(())
    }

    // will fail if already stopped (to prevent duplicate code execution)
    public func stop() -> Promise<Void> {
        guard state != .stopped else {
            return Promise(TrackError.state(message: "Already stopped"))
        }

        if let videoTrack = mediaTrack as? RTCVideoTrack {
            DispatchQueue.webRTC.sync { videoTrack.remove(self) }
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

// MARK: - Internal

internal extension Track {

    func set(stats newValue: TrackStats) {
        guard self.stats != newValue else { return }
        self.stats = newValue
        notify { $0.track(self, didUpdate: newValue) }
    }
}

// MARK: - Private

private extension Track {

    func set(dimensions newValue: Dimensions?) {
        guard self.dimensions != newValue else { return }

        //        DispatchQueue.mainSafeSync {
        self.dimensions = newValue
        //        }

        guard let videoTrack = self as? VideoTrack else { return }
        notify { $0.track(videoTrack, didUpdate: newValue) }
    }

    func set(videoFrame newValue: RTCVideoFrame?) {
        // guard self.videoFrame != newValue else { return }
        self.videoFrame = newValue

        guard let videoTrack = self as? VideoTrack else { return }
        notify { $0.track(videoTrack, didReceive: self.videoFrame) }
    }
}

extension Track: RTCVideoRenderer {

    public func setSize(_ size: CGSize) {
        // guard let videoTrack = self as? VideoTrack else { return }
        // notify { $0.track(videoTrack, didReceive: size) }
    }

    public func renderFrame(_ frame: RTCVideoFrame?) {

        if let frame = frame {
            let dimensions = Dimensions(width: frame.width,
                                        height: frame.height)
            // ignore unsafe dimensions
            guard dimensions.isRenderSafe else {
                log("Skipping render for dimension \(dimensions)", .warning)
                // renderState.insert(.didSkipUnsafeFrame)
                return
            }

            set(dimensions: dimensions)
        } else {
            set(dimensions: nil)
        }

        set(videoFrame: frame)
    }
}
