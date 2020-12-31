//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/10/20.
//

import Foundation

public class Participant {
    public typealias Sid = String
    
    var info: Livekit_ParticipantInfo?
    
    public internal(set) var sid: Participant.Sid?
    public internal(set) var name: String?
    
    var tracks: [TrackPublication] = []
    public internal(set) var audioTracks: [TrackPublication] = []
    public internal(set) var videoTracks: [TrackPublication] = []
    public internal(set) var dataTracks: [TrackPublication] = []
    
    init(sid: Participant.Sid, name: String?) {
        self.sid = sid
        self.name = name
    }
}

extension Participant: Hashable {
    public static func == (lhs: Participant, rhs: Participant) -> Bool {
        return lhs.sid == rhs.sid
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(sid)
    }
}
