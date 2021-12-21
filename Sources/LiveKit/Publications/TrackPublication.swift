import Foundation

extension TrackPublication: Equatable {
    // objects are considered equal if sids are the same
    public static func == (lhs: TrackPublication, rhs: TrackPublication) -> Bool {
        lhs.sid == rhs.sid
    }
}

public class TrackPublication: TrackDelegate {

    public let sid: Sid
    public let kind: Track.Kind
    public let source: Track.Source
    public internal(set) var name: String
    public internal(set) var track: Track? {
        didSet {
            guard oldValue != track else { return }

            // listen for visibility updates
            oldValue?.remove(delegate: self)
            track?.add(delegate: self)
        }
    }

    public var muted: Bool {
        track?.muted ?? false
    }

    /// video-only
    public internal(set) var dimensions: Dimensions?

    /// video-only
    public internal(set) var simulcasted: Bool = false

    weak var participant: Participant?

    public var subscribed: Bool { return track != nil }

    init(info: Livekit_TrackInfo, track: Track? = nil, participant: Participant? = nil) {
        sid = info.sid
        name = info.name
        kind = info.type.toLKType()
        source = info.source.toLKType()
        self.track = track
        self.participant = participant
        updateFromInfo(info: info)

        // listen for events from Track
        track?.add(delegate: self)
    }

    internal func updateFromInfo(info: Livekit_TrackInfo) {
        // only muted and name can conceivably update
        name = info.name
        simulcasted = info.simulcast
        if info.type == .video {
            dimensions = Dimensions(width: Int32(info.width),
                                    height: Int32(info.height))
        }
    }

    // MARK: - TrackDelegate

    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize) {
        //
    }

    public func track(_ track: VideoTrack, didAttach videoView: VideoView) {
        //
    }

    public func track(_ track: VideoTrack, didDetach videoView: VideoView) {
        //
    }

    public func track(_ track: Track, didUpdate muted: Bool, shouldSendSignal: Bool) {
        //
        logger.debug("track didUpdate muted: \(muted) shouldSendSignal: \(shouldSendSignal)")

        guard let participant = participant else {
            logger.warning("Participant is nil")
            return
        }

        if shouldSendSignal {
            participant.room?.engine.signalClient.sendMuteTrack(trackSid: sid, muted: muted)
        }

        participant.notify { $0.participant(participant, didUpdate: self, muted: muted) }
        participant.room?.notify { $0.room(participant.room!, participant: participant, didUpdate: self, muted: self.muted) }
    }
}
