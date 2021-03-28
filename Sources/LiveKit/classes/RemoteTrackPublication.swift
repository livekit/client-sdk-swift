//
//  File.swift
//  
//
//  Created by David Zhao on 3/26/21.
//

import Foundation

public class RemoteTrackPublication : TrackPublication {
    var unsubscribed: Bool = true
    var disabled: Bool = false
    var videoQuality: VideoQuality = .high
    
    override public var subscribed: Bool {
        get {
            if unsubscribed {
                return false
            }
            return super.subscribed
        }
    }
    
    /// subscribe or unsubscribe from this track
    public func setSubscribed(_ subscribed: Bool) {
        unsubscribed = !subscribed
        guard let client = self.participant?.room?.engine.client else {
            return
        }
        
        do {
            try client.sendUpdateSubscription(sid: sid,
                                              subscribed: !unsubscribed,
                                              videoQuality: videoQuality.toProto())
        } catch {
            // TODO: log error
        }
    }
    
    /// disable server from sending down data for this track
    ///
    /// this is useful when the participant is off screen, you may disable streaming down their video to reduce bandwidth requirements
    public func setEnabled(_ enabled: Bool) {
        disabled = !disabled
        sendTrackSettings()
    }
    
    /// for tracks that support simulcasting, adjust subscribed quality
    ///
    /// this indicates the highest quality the client can accept. if network bandwidth does not allow, server will automatically reduce quality to optimize
    /// for uninterrupted video
    public func setVideoQuality(_ quality: VideoQuality) {
        videoQuality = quality
        sendTrackSettings()
    }
    
    func sendTrackSettings() {
        guard let client = self.participant?.room?.engine.client else {
            return
        }
        
        do {
            try client.sendUpdateTrackSettings(sid: self.sid,
                                               disabled: self.disabled,
                                               videoQuality: self.videoQuality.toProto())
        } catch {
            // TODO: log error
        }
    }
}
