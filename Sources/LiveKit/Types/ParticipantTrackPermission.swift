import Foundation

public struct ParticipantTrackPermission {
    /**
     * The participant id this permission applies to.
     */
    let participantSid: String

    /**
     * If set to true, the target participant can subscribe to all tracks from the local participant.
     *
     * Takes precedence over ``allowedTrackSids``.
     */
    let allTracksAllowed: Bool

    /**
     * The list of track ids that the target participant can subscribe to.
     */
    let allowedTrackSids: [String]

    public init(participantSid: String,
                allTracksAllowed: Bool,
                allowedTrackSids: [String] = [String]()) {
        self.participantSid = participantSid
        self.allTracksAllowed = allTracksAllowed
        self.allowedTrackSids = allowedTrackSids
    }
}

extension ParticipantTrackPermission {
    func toPBType() -> Livekit_TrackPermission {
        return Livekit_TrackPermission.with {
            $0.participantSid = self.participantSid
            $0.allTracks = self.allTracksAllowed
            $0.trackSids = self.allowedTrackSids
        }
    }
}
