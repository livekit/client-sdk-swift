//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/15/20.
//

import Foundation
import WebRTC

enum TrackError: Error {
    case invalidTrackType(String)
}

public class Track {
    public typealias Sid = String
    public internal(set) var sid: Track.Sid
    
    init(sid: Track.Sid) {
        self.sid = sid
    }
}
