//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/28/20.
//

import Foundation
import WebRTC

public class VideoTrack: MediaTrack {
    var videoTrack: RTCVideoTrack {
        get { return mediaTrack as! RTCVideoTrack }
        set { mediaTrack = newValue }
    }
   
    init(rtcTrack: RTCVideoTrack, name: String) {
//        let state = try! Track.stateFromRTCMediaTrackState(rtcState: rtcTrack.readyState)
        super.init(name: name, kind: .video, track: rtcTrack)
    }
    
    public func addRenderer(_ renderer: RTCVideoRenderer) {
        videoTrack.add(renderer)
    }
    
    public func removeRenderer(_ renderer: RTCVideoRenderer) {
        videoTrack.remove(renderer)
    }
}
