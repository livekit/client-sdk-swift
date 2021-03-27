//
//  File.swift
//  
//
//  Created by David Zhao on 3/26/21.
//

import Foundation

public class LocalTrackPublication : TrackPublication {
    /// Mute or unmute this track
    public func setMuted(_ muted: Bool) {
        guard self.muted != muted else {
            return
        }
        
        // mute the tracks and stop sending data
        guard let mediaTrack = track as? MediaTrack else {
            return
        }
        
        mediaTrack.mediaTrack.isEnabled = !muted
        self.muted = muted
        
        // send server flag
        guard let participant = self.participant as? LocalParticipant else {
            return
        }
        participant.room?.engine.client.sendMuteTrack(trackSid: sid, muted: muted)
        
        // trigger muted event
        if muted {
            participant.delegate?.didMute(publication: self, participant: participant)
            participant.room?.delegate?.didMute(publication: self, participant: participant)
        } else {
            participant.delegate?.didUnmute(publication: self, participant: participant)
            participant.room?.delegate?.didUnmute(publication: self, participant: participant)
        }
    }
}
