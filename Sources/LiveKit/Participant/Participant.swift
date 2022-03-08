import Foundation
import WebRTC

public class Participant: MulticastDelegate<ParticipantDelegate> {

    public let sid: Sid
    public internal(set) var identity: String
    public internal(set) var name: String
    public internal(set) var audioLevel: Float = 0.0
    public internal(set) var isSpeaking: Bool = false {
        didSet {
            guard oldValue != isSpeaking else { return }
            notify { $0.participant(self, didUpdate: self.isSpeaking) }
            // relavent event for Room doesn't exist yet...
        }
    }

    public internal(set) var metadata: String? {
        didSet {
            guard oldValue != metadata else { return }
            notify { $0.participant(self, didUpdate: self.metadata) }
            room.notify { $0.room(self.room, participant: self, didUpdate: self.metadata) }
        }
    }

    public internal(set) var connectionQuality: ConnectionQuality = .unknown {
        didSet {
            guard oldValue != connectionQuality else { return }
            notify { $0.participant(self, didUpdate: self.connectionQuality) }
            room.notify { $0.room(self.room, participant: self, didUpdate: self.connectionQuality) }
        }
    }

    public private(set) var joinedAt: Date?
    public internal(set) var tracks = [String: TrackPublication]()

    public var audioTracks: [TrackPublication] {
        tracks.values.filter { $0.kind == .audio }
    }

    public var videoTracks: [TrackPublication] {
        tracks.values.filter { $0.kind == .video }
    }

    var info: Livekit_ParticipantInfo?

    // Reference to the Room this Participant belongs to
    public let room: Room

    public init(sid: String,
                identity: String,
                name: String,
                room: Room) {

        self.sid = sid
        self.identity = identity
        self.name = name
        self.room = room
    }

    func addTrack(publication: TrackPublication) {
        tracks[publication.sid] = publication
        publication.track?.sid = publication.sid
    }

    func updateFromInfo(info: Livekit_ParticipantInfo) {
        self.identity = info.identity
        self.name = info.name
        self.metadata = info.metadata
        self.joinedAt = Date(timeIntervalSince1970: TimeInterval(info.joinedAt))
        self.info = info
    }
}

// MARK: - Simplified API

extension Participant {

    public func isCameraEnabled() -> Bool {
        !(getTrackPublication(source: .camera)?.muted ?? true)
    }

    public func isMicrophoneEnabled() -> Bool {
        !(getTrackPublication(source: .microphone)?.muted ?? true)
    }

    public func isScreenShareEnabled() -> Bool {
        !(getTrackPublication(source: .screenShareVideo)?.muted ?? true)
    }

    func getTrackPublication(name: String) -> TrackPublication? {
        tracks.values.first(where: { $0.name == name })
    }

    /// find the first publication matching `source` or any compatible.
    func getTrackPublication(source: Track.Source) -> TrackPublication? {
        // if source is unknown return nil
        guard source != .unknown else { return nil }
        // try to find a Publication with matching source
        if let result = tracks.values.first(where: { $0.source == source }) {
            return result
        }
        // try to find a compatible Publication
        if let result = tracks.values.filter({ $0.source == .unknown }).first(where: {
            (source == .microphone && $0.kind == .audio) ||
                (source == .camera && $0.kind == .video && $0.name != Track.screenShareName) ||
                (source == .screenShareVideo && $0.kind == .video && $0.name == Track.screenShareName) ||
                (source == .screenShareAudio && $0.kind == .audio && $0.name == Track.screenShareName)
        }) {
            return result
        }

        return nil
    }
}

// MARK: - Equality

extension Participant {

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(sid)
        return hasher.finalize()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Participant else {
            return false
        }
        return sid == other.sid
    }
}
