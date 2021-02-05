//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation
import WebRTC

public class RemoteParticipant: Participant {
    
    public var remoteAudioTracks: [TrackPublication] { audioTracks }
    public var remoteVideoTracks: [TrackPublication] { videoTracks }
    public var remoteDataTracks: [TrackPublication] { dataTracks }
    
    public weak var delegate: RemoteParticipantDelegate?
        
    override var info: Livekit_ParticipantInfo? {
        didSet {
            do {
                try updateFromInfo()
            } catch {
                print(error)
            }
        }
    }
    
    convenience init(info: Livekit_ParticipantInfo) {
        self.init(sid: info.sid, name: info.name)
        self.info = info
    }
    
    func updateFromInfo() throws {
        sid = info!.sid
        name = info!.name
        
        var validTrackSids = Set<String>()
        var newPublications: [TrackPublication] = []
        
        for trackInfo in info!.tracks {
            var publication = tracks.first(where: { $0.trackSid == trackInfo.sid })
            if publication == nil {
                switch trackInfo.type {
                case .audio:
                    publication = RemoteAudioTrackPublication(info: trackInfo)
                case .video:
                    publication = RemoteVideoTrackPublication(info: trackInfo)
                case .data:
                    publication = RemoteDataTrackPublication(info: trackInfo)
                default:
                    throw TrackError.invalidTrackType("Error: Invalid track type")
                }
                addTrack(publication: publication!)
                newPublications.append(publication!)
            } else {
                publication?.trackName = trackInfo.name
                publication?.track?.name = trackInfo.name
            }
            validTrackSids.insert(publication!.trackSid)
        }
        
        if info != nil {
            for publication in newPublications {
                try sendTrackPublishedEvent(publication: publication)
            }
        }
        
        for track in tracks where !validTrackSids.contains(track.trackSid) {
            try unpublishTrack(publication: track)
        }
    }
    
    func addSubscribedMediaTrack(rtcTrack: RTCMediaStreamTrack, sid: Track.Sid) throws {
        var track: Track
        var publication = tracks.first(where: { $0.trackSid == sid })
        
        switch rtcTrack.kind {
        case "audio":
            track = RemoteAudioTrack(sid: sid, rtcTrack: rtcTrack as! RTCAudioTrack, name: "")
        case "video":
            track = RemoteVideoTrack(sid: sid, rtcTrack: rtcTrack as! RTCVideoTrack, name: "")
        default:
            throw TrackError.invalidTrackType("Error: Invalid track type")
        }
        
        if publication != nil {
            track.name = publication!.trackName
            publication!.track = track
        } else {
            var trackInfo = Livekit_TrackInfo()
            trackInfo.sid = sid
            
            switch rtcTrack.kind {
            case "audio":
                publication = RemoteAudioTrackPublication(info: trackInfo, track: track)
            case "video":
                publication = RemoteVideoTrackPublication(info: trackInfo, track: track)
            default:
                break
            }
            addTrack(publication: publication!)
            if info != nil {
                try sendTrackPublishedEvent(publication: publication!)
            }
        }
        
        switch publication {
        case is RemoteAudioTrackPublication:
            delegate?.didSubscribe(audioTrack: publication as! RemoteAudioTrackPublication, participant: self)
        case is RemoteVideoTrackPublication:
            delegate?.didSubscribe(videoTrack: publication as! RemoteVideoTrackPublication, participant: self)
        default:
            throw TrackError.invalidTrackType("Error: Invalid track type")
        }
    }
    
    func addSubscribedDataTrack(rtcTrack: RTCDataChannel, sid: Track.Sid, name: String) throws {
        let track = RemoteDataTrack(sid: sid, rtcTrack: rtcTrack, name: name)
        var publication = tracks.first(where: { $0.trackSid == sid })
        
        if publication != nil {
            publication!.track = track
        } else {
            var trackInfo = Livekit_TrackInfo()
            trackInfo.sid = sid
            trackInfo.name = name
            trackInfo.type = .data
            publication = RemoteDataTrackPublication(info: trackInfo, track: track)
            addTrack(publication: publication!)
            if info != nil {
                try sendTrackPublishedEvent(publication: publication!)
            }
        }
    }
    
    func addTrack(publication: TrackPublication) {
        tracks.append(publication)
        switch publication {
        case is RemoteAudioTrackPublication:
            audioTracks.append(publication)
        case is RemoteVideoTrackPublication:
            videoTracks.append(publication)
        default:
            break
        }
    }
    
    func unpublishTrack(publication: TrackPublication, silent: Bool = true) throws {
        tracks.removeAll(where: { $0.trackSid == publication.trackSid })
        switch publication {
        case is RemoteAudioTrackPublication:
            audioTracks.removeAll(where: { $0.trackSid == publication.trackSid })
        case is RemoteVideoTrackPublication:
            videoTracks.removeAll(where: { $0.trackSid == publication.trackSid })
        default:
            throw TrackError.invalidTrackType("Error: Invalid track type")
        }
    }
    
    func unpublishTrack(sid: Track.Sid, silent: Bool = true) throws {
        if let publication = tracks.first(where: { $0.trackSid == sid }) {
            try unpublishTrack(publication: publication, silent: silent)
        }
    }
    
    func unpublishTracks() throws {
        for trackPublication in tracks {
            try unpublishTrack(publication: trackPublication)
        }
    }
    
    private func sendTrackPublishedEvent(publication: TrackPublication) throws {
        switch publication {
        case is RemoteAudioTrackPublication:
            delegate?.didPublish(audioTrack: publication as! RemoteAudioTrackPublication, participant: self)
        case is RemoteVideoTrackPublication:
            delegate?.didPublish(videoTrack: publication as! RemoteVideoTrackPublication, participant: self)
        case is RemoteDataTrackPublication:
            delegate?.didPublish(dataTrack: publication as! RemoteDataTrackPublication, participant: self)
        default:
            throw TrackError.invalidTrackType("Error: Invalid track type")
        }
    }
}
