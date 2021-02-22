//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/10/20.
//

import Foundation

public class Participant: NSObject {
    public typealias Sid = String
    
    var metadata: String?
    
    public internal(set) var sid: Participant.Sid?
    public internal(set) var name: String?
    public internal(set) var audioLevel: Float = 0.0
    
    var tracks = [Track.Sid: TrackPublication]()
    public internal(set) var audioTracks = [Track.Sid: TrackPublication]()
    public internal(set) var videoTracks = [Track.Sid: TrackPublication]()
    public internal(set) var dataTracks = [Track.Sid: TrackPublication]()
    
    init(sid: Participant.Sid, name: String?) {
        self.sid = sid
        self.name = name
    }
    
    func addTrack(publication: TrackPublication) {
        tracks[publication.trackSid] = publication
        switch publication {
        case is RemoteAudioTrackPublication:
            audioTracks[publication.trackSid] = publication
        case is RemoteVideoTrackPublication:
            videoTracks[publication.trackSid] = publication
        case is RemoteDataTrackPublication:
            dataTracks[publication.trackSid] = publication
        default:
            break
        }
    }
    
    public override func isEqual(_ object: Any?) -> Bool {
        if let other = object as? Participant {
            return sid == other.sid
        } else {
            return false
        }
    }
}
