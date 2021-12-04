import SwiftUI
import WebRTC

extension ObservableParticipant: Identifiable {
    public var id: String {
        participant.sid
    }
}

extension ObservableParticipant: Equatable & Hashable {

    public static func == (lhs: ObservableParticipant, rhs: ObservableParticipant) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ObservableParticipant {
    public var identity: String? {
        participant.identity
    }
}

open class ObservableParticipant<T: Participant>: ObservableObject {

    public let participant: T

    @Published public private(set) var firstCameraPublication: TrackPublication?
    @Published public private(set) var firstScreenSharePublication: TrackPublication?
    @Published public private(set) var firstAudioPublication: TrackPublication?

    public var firstCameraVideoTrack: VideoTrack? {
        guard let pub = firstCameraPublication, !pub.muted,
              let track = pub.track else { return nil }
        return track as? VideoTrack
    }

    public var firstScreenShareVideoTrack: VideoTrack? {
        guard let pub = firstScreenSharePublication, !pub.muted,
              let track = pub.track else { return nil }
        return track as? VideoTrack
    }

    public var firstAudioTrack: AudioTrack? {
        guard let pub = firstAudioPublication, !pub.muted,
              let track = pub.track else { return nil }
        return track as? AudioTrack
    }

    public var firstVideoAvailable: Bool {
        firstCameraVideoTrack != nil
    }

    public var firstAudioAvailable: Bool {
        firstAudioTrack != nil
    }

    @Published public private(set) var isSpeaking: Bool = false

    @Published public private(set) var connectionQuality: ConnectionQuality = .unknown

    public init(_ participant: T) {
        self.participant = participant
        participant.add(delegate: self)
        recomputeFirstTracks()
    }

    deinit {
        participant.remove(delegate: self)
    }

    private func recomputeFirstTracks() {
        DispatchQueue.main.async {
            self.firstCameraPublication = self.participant.videoTracks.first(where: { $0.source == .camera })
            self.firstScreenSharePublication = self.participant.videoTracks.first(where: { $0.source == .screenShareVideo })
            self.firstAudioPublication = self.participant.audioTracks.first
        }
    }
}

extension ObservableParticipant: ParticipantDelegate {

    public func participant(_ participant: RemoteParticipant,
                            didSubscribe trackPublication: RemoteTrackPublication,
                            track: Track) {
        recomputeFirstTracks()
    }

    public func participant(_ participant: RemoteParticipant,
                            didUnsubscribe trackPublication: RemoteTrackPublication,
                            track: Track) {
        recomputeFirstTracks()
    }

    public func localParticipant(_ participant: LocalParticipant,
                                 didPublish trackPublication: LocalTrackPublication) {
        recomputeFirstTracks()
    }

    public func localParticipant(_ participant: LocalParticipant,
                                 didUnpublish trackPublication: LocalTrackPublication) {
        recomputeFirstTracks()
    }

    public func participant<T: Participant>(_ participant: T,
                                            didUpdate trackPublication: TrackPublication, muted: Bool) {
        recomputeFirstTracks()
    }

    public func participant<T: Participant>(_ participant: T, didUpdate speaking: Bool) {
        DispatchQueue.main.async {
            self.isSpeaking = speaking
        }
    }

    public func participant<T: Participant>(_ participant: T, didUpdate connectionQuality: ConnectionQuality) {
        DispatchQueue.main.async {
            self.connectionQuality = connectionQuality
        }
    }
}
