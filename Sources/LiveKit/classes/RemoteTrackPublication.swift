//
//  File.swift
//  
//
//  Created by David Zhao on 3/26/21.
//

import Foundation

public class RemoteTrackPublication : TrackPublication {
    // subscribe or unsubscribe from this track
    func setSubscribed(_ subscribed: Bool) {
        
    }
    
    // disable server from sending down data for this track
    func setDisabled(_ disabled: Bool) {
        
    }
    
    // attempt to swith to a different quality. only available for video tracks
    func setVideoQuality(_ quality: Livekit_VideoQuality) {
    }
}
