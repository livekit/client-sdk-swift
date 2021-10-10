//
//  File.swift
//
//
//  Created by David Zhao on 3/26/21.
//

import Foundation

public class LocalTrackPublication: TrackPublication {
    /// Mute or unmute this track
    ///
    /// Muting the track would stop audio or video from being transmitted to the server, and notify other participants in the room.
    public func setMuted(_ muted: Bool) {
        guard self.muted != muted else {
            return
        }

        // mute the tracks and stop sending data
        guard let mediaTrack = track else {
            return
        }

        mediaTrack.mediaTrack.isEnabled = !muted
        self.muted = muted

        // send server flag
        guard let participant = self.participant as? LocalParticipant else {
            return
        }
        participant.room?.engine.signalClient.sendMuteTrack(trackSid: sid, muted: muted)

        // trigger muted event
        if muted {
            participant.notify { $0.didMute(publication: self, participant: participant) }
            participant.room?.notify { $0.didMute(publication: self, participant: participant) }
        } else {
            participant.notify { $0.didUnmute(publication: self, participant: participant) }
            participant.room?.notify { $0.didUnmute(publication: self, participant: participant) }
        }
    }
}
