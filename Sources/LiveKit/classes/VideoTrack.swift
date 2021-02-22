//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/28/20.
//

import Foundation
import WebRTC

public class VideoTrack: Track, MediaTrack {
    var rtcTrack: RTCVideoTrack
    var mediaTrack: RTCMediaStreamTrack {
        get { rtcTrack }
    }
    public var enabled: Bool {
        get { rtcTrack.isEnabled }
        set { rtcTrack.isEnabled = newValue }
    }
    
    init(rtcTrack: RTCVideoTrack, name: String) {
        self.rtcTrack = rtcTrack
        let state = try! Track.stateFromRTCMediaTrackState(rtcState: rtcTrack.readyState)
        super.init(name: name, state: state)
    }
    
    public func addRenderer(_ renderer: RTCVideoRenderer) {
        rtcTrack.add(renderer)
    }
    
    public func removeRenderer(_ renderer: RTCVideoRenderer) {
        rtcTrack.remove(renderer)
    }
}
