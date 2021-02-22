//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/30/20.
//

import Foundation
import WebRTC

public class DataTrack: Track {
    var rtcTrack: RTCDataChannel?
    
    public var ordered: Bool? {
        get { rtcTrack?.isOrdered }
    }
    public var maxPacketLifeTime: UInt16? {
        get { rtcTrack?.maxPacketLifeTime }
    }
    public var maxRetransmits: UInt16? {
        get { rtcTrack?.maxRetransmits }
    }
    
    init(rtcTrack: RTCDataChannel? = nil, name: String) {
        self.rtcTrack = rtcTrack
        var state: Track.State = .none
        
        if let t = rtcTrack {
            state = try! Track.stateFromRTCDataChannelState(rtcState: t.readyState)
        }
        super.init(name: name, state: state)
    }
}
