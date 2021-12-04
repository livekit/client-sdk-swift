import Foundation

public class LocalTrackPublication: TrackPublication {
    
    typealias ParticipantType = LocalParticipant

    /// Mute or unmute this track
    ///
    /// Muting the track would stop audio or video from being transmitted to the server, and notify other participants in the room.
    public override var muted: Bool {
        didSet {
            guard oldValue != muted else { return }

            // mute the tracks and stop sending data
            guard let mediaTrack = track else { return }

            mediaTrack.mediaTrack.isEnabled = !muted

            // send server flag
            guard let participant = self.participant as? LocalParticipant else {
                return
            }

            participant.notify { $0.participant(participant, didUpdate: self, muted: self.muted) }
            if let room = participant.room {
                room.engine.signalClient.sendMuteTrack(trackSid: sid, muted: muted)
                room.notify { $0.room(participant.room!, participant: participant, didUpdate: self, muted: self.muted) }
            }
        }
    }
}
