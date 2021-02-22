//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation
import WebRTC

public class RemoteParticipant: Participant {
    
    public var remoteAudioTracks: [TrackPublication] { Array(audioTracks.values) }
    public var remoteVideoTracks: [TrackPublication] { Array(videoTracks.values) }
    public var remoteDataTracks: [TrackPublication] { Array(dataTracks.values) }
    
    public weak var delegate: RemoteParticipantDelegate?
        
    var participantInfo: Livekit_ParticipantInfo?
    
    var hasInfo: Bool {
        get {
            return participantInfo != nil
        }
    }
    
    convenience init(info: Livekit_ParticipantInfo) {
        self.init(sid: info.sid, name: info.identity)
        try? updateFromInfo(info: info)
    }
    
    func getTrackPublication(_ sid: Track.Sid) -> RemoteTrackPublication? {
        tracks[sid] as? RemoteTrackPublication
    }
    
    func updateFromInfo(info: Livekit_ParticipantInfo) throws {
        let alreadyHadInfo = hasInfo
        
        sid = info.sid
        name = info.identity
        participantInfo = info
        metadata = info.metadata
        
        var validTrackPublications = [Track.Sid: RemoteTrackPublication]()
        var newTrackPublications = [Track.Sid: RemoteTrackPublication]()
        
        for trackInfo in info.tracks {
            var publication = getTrackPublication(trackInfo.sid)
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
                newTrackPublications[trackInfo.sid] = publication!
                addTrack(publication: publication!)
            } else {
                publication!.updateFromInfo(info: trackInfo)
            }
            validTrackPublications[trackInfo.sid] = publication!
        }
        
        if alreadyHadInfo {
            for publication in newTrackPublications.values {
                try sendTrackPublishedEvent(publication: publication)
            }
        }
        
        for trackPublication in tracks.values where validTrackPublications[trackPublication.trackSid] == nil {
            try unpublishTrack(sid: trackPublication.trackSid, sendUnpublish: true)
        }
    }
    
    func addSubscribedMediaTrack(rtcTrack: RTCMediaStreamTrack, sid: Track.Sid, triesLeft: Int = 20) throws {
        var track: Track
        let publication = getTrackPublication(sid)
        
        switch rtcTrack.kind {
        case "audio":
            track = RemoteAudioTrack(sid: sid, rtcTrack: rtcTrack as! RTCAudioTrack, name: "")
        case "video":
            track = RemoteVideoTrack(sid: sid, rtcTrack: rtcTrack as! RTCVideoTrack, name: "")
        default:
            throw TrackError.invalidTrackType("Error: Invalid track type")
        }
        
        guard publication != nil else {
            if triesLeft == 0 {
                print("remote participant \(String(describing: self.sid)) --- could not find published track with sid: ", sid)
                switch rtcTrack.kind {
                case "audio":
                    delegate?.didFailToSubscribe(audioTrack: track as! RemoteAudioTrack,
                                                 error: TrackError.invalidTrackState("Could not find published track with sid: \(sid)"),
                                                 participant: self)
                case "video":
                    delegate?.didFailToSubscribe(videoTrack: track as! RemoteVideoTrack,
                                                 error: TrackError.invalidTrackState("Could not find published track with sid: \(sid)"),
                                                 participant: self)
                default:
                    break
                }
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                do {
                    try self.addSubscribedMediaTrack(rtcTrack: rtcTrack, sid: sid, triesLeft: triesLeft - 1)
                } catch {
                    print("remote participant --- error: \(error)")
                }
            }
            return
        }
        
        publication!.track = track
        track.name = publication!.trackName
        var t = track as! RemoteTrack
        t.sid = publication!.trackSid
        
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
        var publication = getTrackPublication(sid)
        
        if publication != nil {
            publication!.track = track
        } else {
            var trackInfo = Livekit_TrackInfo()
            trackInfo.sid = sid
            trackInfo.name = name
            trackInfo.type = .data
            publication = RemoteDataTrackPublication(info: trackInfo, track: track)
            addTrack(publication: publication!)
            if hasInfo {
                try sendTrackPublishedEvent(publication: publication!)
            }
        }
        
        rtcTrack.delegate = self
        delegate?.didSubscribe(dataTrack: publication! as! RemoteDataTrackPublication, participant: self)
    }
    
    func unpublishTrack(sid: Track.Sid, sendUnpublish: Bool = false) throws {
        guard let publication = tracks.removeValue(forKey: sid) else {
            return
        }
        
        switch publication {
        case is RemoteAudioTrackPublication:
            audioTracks.removeValue(forKey: sid)
        case is RemoteVideoTrackPublication:
            videoTracks.removeValue(forKey: sid)
        case is RemoteDataTrackPublication:
            dataTracks.removeValue(forKey: sid)
        default:
            throw TrackError.invalidTrackType("Error: Invalid track type")
        }
        
        if publication.track != nil {
            // FIX: need to stop the track somehow?
            publication.track = nil
            try sendTrackUnsubscribedEvent(publication: publication)
        }
        if (sendUnpublish) {
            try sendTrackUnpublishedEvent(publication: publication)
        }
    }
    
    private func sendTrackUnsubscribedEvent(publication: TrackPublication) throws {
        switch publication {
        case is RemoteAudioTrackPublication:
            delegate?.didUnsubscribe(audioTrack: publication as! RemoteAudioTrackPublication, participant: self)
        case is RemoteVideoTrackPublication:
            delegate?.didUnsubscribe(videoTrack: publication as! RemoteVideoTrackPublication, participant: self)
        case is RemoteDataTrackPublication:
            delegate?.didUnsubscribe(dataTrack: publication as! RemoteDataTrackPublication, participant: self)
        default:
            throw TrackError.invalidTrackType("Error: Invalid track type")
        }
    }
    
    private func sendTrackUnpublishedEvent(publication: TrackPublication) throws {
        switch publication {
        case is RemoteAudioTrackPublication:
            delegate?.didUnpublish(audioTrack: publication as! RemoteAudioTrackPublication, participant: self)
        case is RemoteVideoTrackPublication:
            delegate?.didUnpublish(videoTrack: publication as! RemoteVideoTrackPublication, participant: self)
        case is RemoteDataTrackPublication:
            delegate?.didUnpublish(dataTrack: publication as! RemoteDataTrackPublication, participant: self)
        default:
            throw TrackError.invalidTrackType("Error: Invalid track type")
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

extension RemoteParticipant: RTCDataChannelDelegate {
    private func getPublicationForDataChannel(_ dataChannel: RTCDataChannel) -> RemoteDataTrackPublication? {
        let publication = dataTracks.values.first { publication in
            if let track = publication.track {
                if let rtcTrack = track as? RemoteDataTrack {
                    return dataChannel === rtcTrack
                }
            }
            return false
        }
        return publication as? RemoteDataTrackPublication
    }
    
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed {
            let publication = getPublicationForDataChannel(dataChannel)
            guard publication != nil else {
                print("remote participant --- error on message receive: could not find publication for data channel")
                return
            }
            delegate?.didUnsubscribe(dataTrack: publication!, participant: self)
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let publication = getPublicationForDataChannel(dataChannel)
        guard publication != nil else {
            print("remote participant --- error on message receive: could not find publication for data channel")
            return
        }
        delegate?.didReceive(data: buffer.data, dataTrack: publication!, participant: self)
    }
}
