//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/16/20.
//

import Foundation
import WebRTC

public class AudioTrack: MediaTrack {
    public private(set) var sinks: [AudioSink]?
    var audioTrack: RTCAudioTrack {
        get { return mediaTrack as! RTCAudioTrack }
        set { mediaTrack = newValue }
    }
    
    init(rtcTrack: RTCAudioTrack, name: String) {
//        let state = try! Track.stateFromRTCMediaTrackState(rtcState: rtcTrack.readyState)
        super.init(name: name, kind: .audio, track: rtcTrack)
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
