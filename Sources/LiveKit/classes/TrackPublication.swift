//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/15/20.
//

import Foundation

public class TrackPublication {
    public internal(set) var track: Track?
    public internal(set) var name: String
    public private(set) var sid: String
    public private(set) var kind: Track.Kind
    public internal(set) var muted: Bool
    
    weak var engine: RTCEngine?
    
    public var subscribed: Bool {
        track != nil
    }
    
    init(info: Livekit_TrackInfo, track: Track? = nil, engine: RTCEngine? = nil) {
        sid = info.sid
        name = info.name
        kind = Track.fromProtoKind(info.type)
        muted = info.muted
        self.track = track
        self.engine = engine
    }
    
    func updateFromInfo(info: Livekit_TrackInfo) {
        // only muted and name can conceivably update
        name = info.name
        muted = info.muted
    }

}
