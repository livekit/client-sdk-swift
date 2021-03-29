//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/10/20.
//

import Foundation

public class Participant : NSObject {
    public typealias Sid = String
    
    public internal(set) var sid: Participant.Sid
    public internal(set) var identity: String?
    public internal(set) var audioLevel: Float = 0.0
    public internal(set) var isSpeaking: Bool = false {
        didSet {
            if oldValue != isSpeaking {
                delegate?.isSpeakingDidChange(participant: self)
            }
        }
    }
    public internal(set) var metadata: String? {
        didSet {
            if oldValue != metadata {
                delegate?.metadataDidChange(participant: self)
                room?.delegate?.metadataDidChange(participant: self)
            }
        }
    }
    public private(set) var joinedAt: Date?
    
    public internal(set) var tracks = [String: TrackPublication]()
    public internal(set) var audioTracks = [String: TrackPublication]()
    public internal(set) var videoTracks = [String: TrackPublication]()
    public internal(set) var dataTracks = [String: TrackPublication]()
    
    var info: Livekit_ParticipantInfo?
    
    weak var room: Room?
    public var delegate: ParticipantDelegate?
    
    public init(sid: String) {
        self.sid = sid
    }
    
    func addTrack(publication: TrackPublication) {
        tracks[publication.sid] = publication
        switch publication.kind {
        case .audio:
            audioTracks[publication.sid] = publication
        case .video:
            videoTracks[publication.sid] = publication
        case .data:
            dataTracks[publication.sid] = publication
        default:
            break
        }
        
        publication.track?.sid = publication.sid
    }
    
    func updateFromInfo(info: Livekit_ParticipantInfo) {
        identity = info.identity
        metadata = info.metadata
        joinedAt = Date(timeIntervalSince1970: TimeInterval(info.joinedAt))
        self.info = info
    }
    
    public override func isEqual(_ object: Any?) -> Bool {
        if let other = object as? Participant {
            return sid == other.sid
        } else {
            return false
        }
    }
}
