//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/28/20.
//

import Foundation
import WebRTC

public class RemoteVideoTrack: VideoTrack, RemoteTrack {
    public internal(set) var sid: Track.Sid
    public internal(set) var switchedOff: Bool
    public internal(set) var priority: Track.Priority?
    
    init(sid: Track.Sid,
         switchedOff: Bool = false,
         priority: Track.Priority? = nil,
         rtcTrack: RTCVideoTrack,
         name: String) {

        self.sid = sid
        self.switchedOff = switchedOff
        self.priority = priority
        super.init(rtcTrack: rtcTrack, name: name)
    }
}
