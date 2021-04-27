//
//  File.swift
//
//
//  Created by David Zhao on 3/25/21.
//

import Foundation
import WebRTC

public class MediaTrack: Track {
    var mediaTrack: RTCMediaStreamTrack

    // TODO: how do we mute a track, disabling is not enough.
//    public var enabled: Bool {
//        get { mediaTrack.isEnabled }
//        set { mediaTrack.isEnabled = newValue }
//    }
    init(name: String, kind: Track.Kind, track: RTCMediaStreamTrack) {
        mediaTrack = track
        super.init(name: name, kind: kind)
    }

    override public func stop() {
        mediaTrack.isEnabled = false
    }
}
