import Foundation
import WebRTC

public protocol Participant: MulticastDelegateCapable {

    associatedtype TrackPublicationType = TrackPublication
    typealias DelegateType = ParticipantDelegate

    var sid: Sid { get }
    var identity: String? { get }

    var audioLevel: Float { get set }
    var isSpeaking: Bool { get set }
    var metadata: String? { get set }
    var connectionQuality: ConnectionQuality { get set }

    var tracks: [String: TrackPublicationType] { get }
    var videoTracks: [TrackPublicationType] { get }
    var audiotracks: [TrackPublicationType] { get }

    var room: Room? { get }
}

extension Participant {

    public func getTrackPublication(sid: String) -> TrackPublicationType? {
        return tracks[sid]
    }

    public func addTrack(publication: TrackPublicationType) {
        tracks[publication.sid] = publication
        publication.track?.sid = publication.sid
    }

    internal func update(commonInfo: Livekit_ParticipantInfo) {
        identity = info.identity
        metadata = info.metadata
        // joinedAt = Date(timeIntervalSince1970: TimeInterval(info.joinedAt))
        // self.info = info
    }

    internal func update(audioLevel: Float) {
        guard self.audioLevel != audioLevel else { return }
        self.audioLevel = audioLevel
    }

    internal func update(isSpeaking: Bool) {
        guard self.isSpeaking != isSpeaking else { return }
        self.isSpeaking = isSpeaking
        notify { $0.participant(self, didUpdate: self.isSpeaking) }
        // relavent event for Room doesn't exist yet...
    }

    internal func update(metadata: String?) {
        guard self.metadata != metadata else { return }
        self.metadata = metadata
        notify { $0.participant(self, didUpdate: self.metadata) }
        room?.notify { $0.room(self.room!, participant: self, didUpdate: self.metadata) }
    }

    internal func update(connectionQuality: ConnectionQuality) {
        guard self.connectionQuality != connectionQuality else { return }
        self.connectionQuality = connectionQuality
        notify { $0.participant(self, didUpdate: self.connectionQuality) }
        room?.notify { $0.room(self.room!, participant: self, didUpdate: self.connectionQuality) }
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

    func getTrackPublication(name: String) -> TrackPublicationType? {
        tracks.values.first(where: { $0.name == name })
    }

    /// find the first publication matching `source` or any compatible.
    func getTrackPublication(source: Track.Source) -> TrackPublicationType? {
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
