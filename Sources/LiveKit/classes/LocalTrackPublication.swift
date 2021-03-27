//
//  File.swift
//  
//
//  Created by David Zhao on 3/26/21.
//

import Foundation

public class LocalTrackPublication : TrackPublication {
    
    func setMuted(_ muted: Bool) {
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
        self.engine?.client.sendMuteTrack(trackSid: sid, muted: muted)
    }
}
