//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/16/20.
//

import Foundation
import WebRTC

public class AudioTrack: Track {
    public private(set) var sinks: [AudioSink]?
    public internal(set) var rtcTrack: RTCMediaStreamTrack
    
    init(sid: Track.Sid, rtcTrack: RTCMediaStreamTrack) {
        self.rtcTrack = rtcTrack
        super.init(sid: sid)
    }
    
    public func addSink(_ sink: AudioSink) {
        sinks?.append(sink)
    }
    
    public func removeSink(_ sink: AudioSink) {
        
    }
}
