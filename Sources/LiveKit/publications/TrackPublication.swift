import Foundation

extension TrackPublication: Equatable {
    // objects are considered equal if sids are the same
    public static func == (lhs: TrackPublication, rhs: TrackPublication) -> Bool {
        lhs.sid == rhs.sid
    }
}

public class TrackPublication {

    public let sid: Sid
    public let kind: Track.Kind
    public internal(set) var name: String
    public internal(set) var track: Track?
    public internal(set) var muted: Bool

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
        muted = info.muted
        self.track = track
        self.participant = participant
        updateFromInfo(info: info)
    }

    func updateFromInfo(info: Livekit_TrackInfo) {
        // only muted and name can conceivably update
        name = info.name
        muted = info.muted
        simulcasted = info.simulcast
        if info.type == .video {
            dimensions = Dimensions(width: Int(info.width), height: Int(info.height))
        }
    }
}
