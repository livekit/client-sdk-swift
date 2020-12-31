//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/15/20.
//

import Foundation

public class TrackPublication {
    public internal(set) var track: Track?
    public private(set) var trackSid: Track.Sid
    public private(set) var trackName: String
//    public internal(set) var trackEnabled: Bool {
//        get {
//            return track != nil
//        }
//    }
    
    required init(info: Livekit_TrackInfo, track: Track? = nil) {
        trackSid = info.sid
        trackName = info.name
    }
}
