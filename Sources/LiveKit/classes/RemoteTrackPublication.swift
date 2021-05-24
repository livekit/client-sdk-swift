//
//  File.swift
//
//
//  Created by David Zhao on 3/26/21.
//

import Foundation

public class RemoteTrackPublication: TrackPublication {
    // have we explicitly unsubscribed
    var unsubscribed: Bool = false
    var disabled: Bool = false
    var videoQuality: VideoQuality = .high

    override public internal(set) var muted: Bool {
        didSet {
            if muted == oldValue {
                return
            }
            guard let participant = self.participant else {
                return
            }
            if muted {
                participant.delegate?.didMute(publication: self, participant: participant)
                participant.room?.delegate?.didMute(publication: self, participant: participant)
            } else {
                participant.delegate?.didUnmute(publication: self, participant: participant)
                participant.room?.delegate?.didUnmute(publication: self, participant: participant)
            }
        }
    }

    override public var subscribed: Bool {
        if unsubscribed {
            return false
        }
        // unless explicitly unsubscribed, defer to parent logic
        return super.subscribed
    }

    /// subscribe or unsubscribe from this track
    public func setSubscribed(_ subscribed: Bool) {
        unsubscribed = !subscribed
        guard let client = participant?.room?.engine.client else {
            return
        }

        client.sendUpdateSubscription(sid: sid,
                                      subscribed: !unsubscribed,
                                      videoQuality: videoQuality.toProto())
    }

    /// disable server from sending down data for this track
    ///
    /// this is useful when the participant is off screen, you may disable streaming down their video to reduce bandwidth requirements
    public func setEnabled(_: Bool) {
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
        guard let client = participant?.room?.engine.client else {
            return
        }

        client.sendUpdateTrackSettings(sid: sid,
                                       disabled: disabled,
                                       videoQuality: videoQuality.toProto())
    }
}
