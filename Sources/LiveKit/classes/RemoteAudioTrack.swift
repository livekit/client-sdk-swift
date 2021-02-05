//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/28/20.
//

import Foundation
import WebRTC

public class RemoteAudioTrack: AudioTrack {
    public internal(set) var sid: Track.Sid
    public internal(set) var playbackEnabled: Bool

    init(sid: Track.Sid,
         playbackEnabled: Bool = true,
         rtcTrack: RTCAudioTrack,
         name: String) {
        
        self.sid = sid
        self.playbackEnabled = playbackEnabled
        super.init(rtcTrack: rtcTrack, name: name)
    }
}
