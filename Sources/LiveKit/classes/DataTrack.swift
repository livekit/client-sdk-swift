//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/30/20.
//

import Foundation
import WebRTC

public class DataTrack: Track {
    public internal(set) var reliable: Bool?
    public internal(set) var ordered: Bool?
    public internal(set) var maxPacketLifeTime: UInt?
    public internal(set) var maxRetransmits: UInt?
    
    public internal(set) var rtcTrack: RTCDataChannel
    public internal(set) var name: String
    
    init(sid: Track.Sid, name: String, rtcTrack: RTCDataChannel) {
        self.rtcTrack = rtcTrack
        self.name = name
        super.init(sid: sid)
    }
}
