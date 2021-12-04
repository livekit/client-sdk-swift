import Foundation

//extension TrackPublication: Equatable {
//    // objects are considered equal if sids are the same
//    public static func == (lhs: TrackPublication, rhs: TrackPublication) -> Bool {
//        lhs.sid == rhs.sid
//    }
//}

public protocol TrackPublication {

    associatedtype ParticipantType = Participant

    var sid: Sid { get }
    var kind: Track.Kind { get}
    var source: Track.Source { get }
    var name: String { get }
    var track: Track? { get }
    var muted: Bool { get }

    /// video-only
//    public internal(set) var dimensions: Dimensions?

    /// video-only
//    public internal(set) var simulcasted: Bool = false

    var participant: ParticipantType? { get }

//    init(info: Livekit_TrackInfo, track: Track? = nil, participant: Participant? = nil) {
//        sid = info.sid
//        name = info.name
//        kind = info.type.toLKType()
//        source = info.source.toLKType()
//        muted = info.muted
//        self.track = track
//        self.participant = participant
//        update(from info: info)
//    }
}

extension TrackPublication {

    public var subscribed: Bool { track != nil }
    
    func update(from info: Livekit_TrackInfo) {
        // only muted and name can conceivably update
        name = info.name
        muted = info.muted
        simulcasted = info.simulcast
//        if info.type == .video {
//            dimensions = Dimensions(width: Int32(info.width),
//                                    height: Int32(info.height))
//        }
    }
}
