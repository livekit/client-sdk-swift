import Foundation
import WebRTC

public class Participant: MulticastDelegate<ParticipantDelegate> {

//    internal let delegates = MulticastDelegate<ParticipantDelegate>()

    public internal(set) var sid: Sid
    public internal(set) var identity: String?
    public internal(set) var audioLevel: Float = 0.0
    public internal(set) var isSpeaking: Bool = false {
        didSet {
            if oldValue != isSpeaking {
                notify { $0.participant(self, didUpdate: self.isSpeaking) }
            }
        }
    }

    public internal(set) var metadata: String? {
        didSet {
            if oldValue != metadata {
                notify { $0.participant(self, didUpdate: self.metadata) }
                room?.notify { $0.room(self.room!, participant: self, didUpdate: self.metadata) }
            }
        }
    }

    public private(set) var joinedAt: Date?

    public internal(set) var tracks = [String: TrackPublication]()

    public var audioTracks: [String: TrackPublication] {
        tracks.filter { $0.value.kind == .audio }
    }

    public var videoTracks: [String: TrackPublication] {
        tracks.filter { $0.value.kind == .video }
    }

    var info: Livekit_ParticipantInfo?

    weak var room: Room?

    public init(sid: String) {
        self.sid = sid
    }

    func addTrack(publication: TrackPublication) {
        tracks[publication.sid] = publication
        publication.track?.sid = publication.sid
    }

    func updateFromInfo(info: Livekit_ParticipantInfo) {
        identity = info.identity
        metadata = info.metadata
        joinedAt = Date(timeIntervalSince1970: TimeInterval(info.joinedAt))
        self.info = info
    }

    override public func isEqual(_ object: Any?) -> Bool {
        if let other = object as? Participant {
            return sid == other.sid
        } else {
            return false
        }
    }
}
