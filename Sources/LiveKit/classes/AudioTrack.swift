//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/16/20.
//

import Foundation
import WebRTC

public class AudioTrack: Track, MediaTrack {
    public private(set) var sinks: [AudioSink]?
    var rtcTrack: RTCAudioTrack
    var mediaTrack: RTCMediaStreamTrack {
        get { rtcTrack }
    }
    
    init(rtcTrack: RTCAudioTrack, name: String) {
        self.rtcTrack = rtcTrack
        let state = try! Track.stateFromRTCMediaTrackState(rtcState: rtcTrack.readyState)
        super.init(enabled: rtcTrack.isEnabled, name: name, state: state)
    }
    
    public func addSink(_ sink: AudioSink) {
        sinks?.append(sink)
    }
    
    public func removeSink(_ sink: AudioSink) {
        sinks?.removeAll(where: { s -> Bool in
            (sink as AnyObject) === (s as AnyObject)
        })
    }
}
