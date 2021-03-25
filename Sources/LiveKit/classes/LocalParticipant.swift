//
//  LocalParticipant.swift
//  
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation
import Promises
import WebRTC

public class LocalParticipant: Participant {
    private var streamId = "stream"
    
    public var localAudioTrackPublications: [TrackPublication] { Array(audioTracks.values) }
    public var localVideoTrackPublications: [TrackPublication] { Array(videoTracks.values) }
    public var localDataTrackPublications: [TrackPublication] { Array(dataTracks.values) }
    
    weak var engine: RTCEngine?
    weak var room: Room?
    
//    public private(set) var signalingRegion: String?
    
    convenience init(fromInfo info: Livekit_ParticipantInfo, engine: RTCEngine, room: Room) {
        self.init(sid: info.sid, name: info.identity)
        self.metadata = info.metadata
        self.engine = engine
        self.room = room
    }
    
    public func publishAudioTrack(track: LocalAudioTrack) {
        publishAudioTrack(track: track, options: nil)
    }
    
    public func publishAudioTrack(track: LocalAudioTrack,
                                  options: LocalTrackPublicationOptions? = LocalTrackPublicationOptions.optionsWithPriority(.standard)) {
        if localAudioTrackPublications.first(where: { $0.track === track }) != nil {
            self.room?.delegate?.didFailToPublishLocalTrack(error: TrackError.publishError("This track has already been published."),
                                                       track: track)
            return
        }
        
        let cid = track.rtcTrack.trackId
        do {
            try engine?.addTrack(cid: cid, name: track.name, kind: .audio)
                .then({ trackInfo in
                    let transInit = RTCRtpTransceiverInit()
                    transInit.direction = .sendOnly
                    transInit.streamIds = [self.streamId]
                    
                    let transceiver = self.engine?.publisher.peerConnection.addTransceiver(with: track.rtcTrack, init: transInit)
                    if transceiver == nil {
                        self.room?.delegate?.didFailToPublishLocalTrack(error: TrackError.publishError("Nil sender returned from peer connection."),
                                                                   track: track)
                        return
                    }
                    
                    let publication = LocalAudioTrackPublication(info: trackInfo, track: track)
                    track.sid = trackInfo.sid
                    self.audioTracks[trackInfo.sid] = publication
                    self.room?.delegate?.didPublishLocalTrack(track: track)
                })
        } catch {
            self.room?.delegate?.didFailToPublishLocalTrack(error: error, track: track)
        }
    }
    
    public func publishVideoTrack(track: LocalVideoTrack) {
        publishVideoTrack(track: track, options: nil)
    }
    
    public func publishVideoTrack(track: LocalVideoTrack,
                                  options: LocalTrackPublicationOptions? = LocalTrackPublicationOptions.optionsWithPriority(.standard)) {
        if localVideoTrackPublications.first(where: { $0.track === track }) != nil {
            self.room?.delegate?.didFailToPublishLocalTrack(error: TrackError.publishError("This track has already been published."),
                                                       track: track)
            return
        }
        
        let cid = track.rtcTrack.trackId
        do {
            try engine?.addTrack(cid: cid, name: track.name, kind: .video)
                .then({ trackInfo in
                    let transInit = RTCRtpTransceiverInit()
                    transInit.direction = .sendOnly
                    transInit.streamIds = [self.streamId]
                    
                    let transceiver = self.engine?.publisher.peerConnection.addTransceiver(with: track.rtcTrack, init: transInit)
                    if transceiver == nil {
                        self.room?.delegate?.didFailToPublishLocalTrack(error: TrackError.publishError("Nil sender returned from peer connection."),
                                                                   track: track)
                        return
                    }
                    
                    let publication = LocalVideoTrackPublication(info: trackInfo, track: track)
                    track.sid = trackInfo.sid
                    self.videoTracks[trackInfo.sid] = publication
                    self.room?.delegate?.didPublishLocalTrack(track: publication.track!)
                })
        } catch {
            self.room?.delegate?.didFailToPublishLocalTrack(error: error, track: track)
        }
    }
    
    public func publishDataTrack(track: LocalDataTrack,
                          options: LocalTrackPublicationOptions? = LocalTrackPublicationOptions.optionsWithPriority(.standard)) {
        if localDataTrackPublications.first(where: { $0.track === track }) != nil {
            return
        }
        
        let cid = track.cid
        do {
            try engine?.addTrack(cid: cid, name: track.name, kind: .data)
                .then({ trackInfo in
                    let publication = LocalDataTrackPublication(info: trackInfo, track: track)
                    track.sid = trackInfo.sid
                    
                    let config = RTCDataChannelConfiguration()
                    config.isOrdered = track.options.ordered
                    config.maxPacketLifeTime = track.options.maxPacketLifeTime
                    config.maxRetransmits = track.options.maxRetransmits
                    
                    if let dataChannel = self.engine?.publisher.peerConnection.dataChannel(forLabel: track.name, configuration: config) {
                        track.rtcTrack = dataChannel
                        self.dataTracks[trackInfo.sid] = publication
                        self.room?.delegate?.didPublishLocalTrack(track: track)
                    } else {
                        try self.unpublishDataTrack(track: track)
                        self.room?.delegate?.didFailToPublishLocalTrack(error: TrackError.publishError("Could not publish data track"), track: track)
                    }
                })
        } catch {
            self.room?.delegate?.didFailToPublishLocalTrack(error: error, track: track)
        }
    }
    
    public func publishDataTrack(track: LocalDataTrack) {
        publishDataTrack(track: track, options: nil)
    }
    
    public func unpublishAudioTrack(track: LocalAudioTrack) throws {
        guard let sid = track.sid else {
            throw TrackError.invalidTrackState("This track was never published.")
        }
        unpublishMediaTrack(track: track, sid: sid, publications: &audioTracks)
    }
    
    public func unpublishVideoTrack(track: LocalVideoTrack) throws {
        guard let sid = track.sid else {
            throw TrackError.invalidTrackState("This track was never published.")
        }
        unpublishMediaTrack(track: track, sid: sid, publications: &videoTracks)
    }
    
    public func unpublishDataTrack(track: LocalDataTrack) throws {
        guard let sid = track.sid else {
            throw TrackError.invalidTrackState("This track was never published.")
        }
        guard let publication = dataTracks.removeValue(forKey: sid) as? LocalDataTrackPublication else {
            print("local participant --- track was not published with sid: \(sid)")
            return
        }
        publication.dataTrack?.rtcTrack?.close()
    }
    
    func setEncodingParameters(parameters: EncodingParameters) {
        
    }
    
    private func unpublishMediaTrack<T>(track: T,
                                        sid: Track.Sid,
                                        publications: inout [Track.Sid : TrackPublication]) where T: Track, T: MediaTrack {
        let publication = publications.removeValue(forKey: sid)
        guard publication != nil else {
            print("local participant --- track was not published with sid: \(sid)")
            return
        }
        
        track.mediaTrack.isEnabled = false
        if let senders = engine?.publisher.peerConnection.senders {
            for sender in senders {
                if let t = sender.track {
                    if t.isEqual(track.mediaTrack) {
                        engine?.publisher.peerConnection.removeTrack(sender)
                    }
                }
            }
        }
    }
}
