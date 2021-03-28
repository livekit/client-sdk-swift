//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation
import WebRTC

public class RemoteParticipant: Participant {

    init(sid: String, info: Livekit_ParticipantInfo?) {
        super.init(sid: sid)
        if info != nil {
            self.updateFromInfo(info: info!)
        }
    }
    
    public func getTrackPublication(sid: String) -> RemoteTrackPublication? {
        return tracks[sid] as? RemoteTrackPublication
    }
    
    override func updateFromInfo(info: Livekit_ParticipantInfo) {
        let hadInfo = self.info != nil
        super.updateFromInfo(info: info)
        
        var validTrackPublications = [String: RemoteTrackPublication]()
        var newTrackPublications = [String: RemoteTrackPublication]()
        
        for trackInfo in info.tracks {
            var publication = getTrackPublication(sid: trackInfo.sid)
            if publication == nil {
                publication = RemoteTrackPublication(info: trackInfo, participant: self)
                newTrackPublications[trackInfo.sid] = publication
                addTrack(publication: publication!)
            } else {
                publication!.updateFromInfo(info: trackInfo)
            }
            validTrackPublications[trackInfo.sid] = publication!
        }
        
        if hadInfo {
            // ensure we are updating only tracks published since joining
            for publication in newTrackPublications.values {
                sendTrackPublishedEvent(publication: publication)
            }
        }
        
        for publication in tracks.values where validTrackPublications[publication.sid] == nil {
            unpublishTrack(sid: publication.sid, sendUnpublish: true)
        }
    }
    
    func addSubscribedMediaTrack(rtcTrack: RTCMediaStreamTrack, sid: String, triesLeft: Int = 20) throws {
        var track: Track
        let publication = getTrackPublication(sid: sid)
        
        guard publication != nil else {
            if triesLeft == 0 {
                print("remote participant \(String(describing: self.sid)) --- could not find published track with sid: ", sid)
                delegate?.didFailToSubscribe(sid: sid,
                                             error: TrackError.invalidTrackState("Could not find published track with sid: \(sid)"),
                                             participant: self)
                self.room?.delegate?.didFailToSubscribe(sid: sid,
                                                        error: TrackError.invalidTrackState("Could not find published track with sid: \(sid)"),
                                                        participant: self)
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
        
        switch rtcTrack.kind {
        case "audio":
            track = AudioTrack(rtcTrack: rtcTrack as! RTCAudioTrack, name: publication!.name)
        case "video":
            track = VideoTrack(rtcTrack: rtcTrack as! RTCVideoTrack, name: publication!.name)
        default:
            throw TrackError.invalidTrackType("Error: Invalid track type")
        }
        
        publication!.track = track
        track.sid = publication!.sid
        addTrack(publication: publication!)
        
        delegate?.didSubscribe(track: track, publication: publication!, participant: self)
        room?.delegate?.didSubscribe(track: track, publication: publication!, participant: self)
    }
    
    func addSubscribedDataTrack(rtcTrack: RTCDataChannel, sid: String, name: String) throws {
        let track = DataTrack(name: name, dataChannel: rtcTrack)
        var publication = getTrackPublication(sid: sid)
        
        if publication != nil {
            publication!.track = track
        } else {
            var trackInfo = Livekit_TrackInfo()
            trackInfo.sid = sid
            trackInfo.name = name
            trackInfo.type = .data
            publication = RemoteTrackPublication(info: trackInfo, track: track, participant: self)
            addTrack(publication: publication!)
        }
        
        rtcTrack.delegate = self
        track.sid = publication!.sid

        delegate?.didSubscribe(track: track, publication: publication!, participant: self)
        room?.delegate?.didSubscribe(track: track, publication: publication!, participant: self)
    }
    
    func unpublishTrack(sid: String, sendUnpublish: Bool = false) {
        guard let publication = tracks.removeValue(forKey: sid) as? RemoteTrackPublication else {
            return
        }
        
        switch publication.kind {
        case .audio:
            audioTracks.removeValue(forKey: sid)
        case .video:
            videoTracks.removeValue(forKey: sid)
        case .data:
            dataTracks.removeValue(forKey: sid)
        default:
            // ignore
        return
        }
        
        if publication.track != nil {
            let track = publication.track!
            track.stop()
            delegate?.didUnsubscribe(track: track,
                                     publication: publication,
                                     participant: self)
            room?.delegate?.didUnsubscribe(track: track,
                                           publication: publication,
                                           participant: self)
        }
        if (sendUnpublish) {
            delegate?.didUnpublishRemoteTrack(publication: publication,
                                              particpant: self)
            room?.delegate?.didUnpublishRemoteTrack(publication: publication,
                                                    particpant: self)
        }
    }
    
    private func sendTrackPublishedEvent(publication: RemoteTrackPublication) {
        delegate?.didPublishRemoteTrack(publication: publication, participant: self)
        room?.delegate?.didPublishRemoteTrack(publication: publication, participant: self)
    }
}

extension RemoteParticipant: RTCDataChannelDelegate {
    private func getPublicationForDataChannel(_ dataChannel: RTCDataChannel) -> RemoteTrackPublication? {
        let publication = dataTracks.values.first { publication in
            if let track = publication.track {
                if let dataTrack = track as? DataTrack {
                    return dataChannel === dataTrack.dataChannel
                }
            }
            return false
        }
        return publication as? RemoteTrackPublication
    }
    
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed {
            let publication = getPublicationForDataChannel(dataChannel)
            guard publication != nil else {
                print("remote participant --- error on message receive: could not find publication for data channel")
                return
            }
            delegate?.didUnsubscribe(track: publication!.track!, publication: publication!, participant: self)
            room?.delegate?.didUnsubscribe(track: publication!.track!, publication: publication!, participant: self)
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let publication = getPublicationForDataChannel(dataChannel)
        guard publication != nil else {
            print("remote participant --- error on message receive: could not find publication for data channel")
            return
        }
        delegate?.didReceive(data: buffer.data, dataTrack: publication!, participant: self)
        room?.delegate?.didReceive(data: buffer.data, dataTrack: publication!, participant: self)
    }
}
