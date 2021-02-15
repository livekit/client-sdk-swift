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
    
    public var localAudioTrackPublications: [TrackPublication] { audioTracks }
    public var localVideoTrackPublications: [TrackPublication] { videoTracks }
    public var localDataTrackPublications: [TrackPublication] { dataTracks }
    
    weak var engine: RTCEngine?
    
//    public private(set) var signalingRegion: String?
    public weak var delegate: LocalParticipantDelegate?
    
    convenience init(fromInfo info: Livekit_ParticipantInfo, engine: RTCEngine) {
        self.init(sid: info.sid, name: info.identity)
        self.info = info
        self.engine = engine
    }
    
    public func publishAudioTrack(track: LocalAudioTrack,
                           options: LocalTrackPublicationOptions? = LocalTrackPublicationOptions.optionsWithPriority(.standard)) {
        if localAudioTrackPublications.first(where: { $0.track === track }) != nil {
            return
        }
        
        let cid = track.rtcTrack.trackId
        do {
            try engine?.addTrack(cid: cid, name: track.name, kind: .audio)
                .then({ trackInfo in
                    let publication = LocalAudioTrackPublication(info: trackInfo, track: track)
                    self.engine?.publisher.peerConnection.add(track.rtcTrack, streamIds: [self.streamId])
                    self.audioTracks.append(publication)
                    self.delegate?.didPublishAudioTrack(track: track)
                })
        } catch {
            print("local participant --- error occurred publishing audio track: \(error)")
        }
    }
    
    public func publishAudioTrack(track: LocalAudioTrack) {
        publishAudioTrack(track: track, options: nil)
    }
    
    public func publishVideoTrack(track: LocalVideoTrack,
                           options: LocalTrackPublicationOptions? = LocalTrackPublicationOptions.optionsWithPriority(.standard)) {
        if localVideoTrackPublications.first(where: { $0.track === track }) != nil {
            return
        }
        
        let cid = track.rtcTrack.trackId
        do {
            try engine?.addTrack(cid: cid, name: track.name, kind: .audio)
                .then({ trackInfo in
                    let publication = LocalVideoTrackPublication(info: trackInfo, track: track)
                    self.engine?.publisher.peerConnection.add(track.rtcTrack, streamIds: [self.streamId])
                    self.videoTracks.append(publication)
                    self.delegate?.didPublishVideoTrack(track: track)
                })
        } catch {
            print("local participant --- error occurred publishing audio track: \(error)")
        }
    }
    
    public func publishVideoTrack(track: LocalVideoTrack) {
        publishVideoTrack(track: track, options: nil)
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
                    
                    let config = RTCDataChannelConfiguration()
                    config.isOrdered = track.options.ordered
                    config.maxPacketLifeTime = track.options.maxPacketLifeTime
                    config.maxRetransmits = track.options.maxRetransmits
                    
                    if let dataChannel = self.engine?.publisher.peerConnection.dataChannel(forLabel: track.name, configuration: config) {
                        track.rtcTrack = dataChannel
                        self.dataTracks.append(publication)
                        self.delegate?.didPublishDataTrack(track: track)
                    } else {
                        print("local participant --- error creating data channel with name: \(track.name)")
                        self.unpublishDataTrack(track: track)
                    }
                })
        } catch {
            print("local participant --- error occurred publishing data track: \(error)")
        }
    }
    
    public func publishDataTrack(track: LocalDataTrack) {
        publishDataTrack(track: track, options: nil)
    }
    
    public func unpublishAudioTrack(track: LocalAudioTrack) {
        unpublishMediaTrack(track: track, publications: &audioTracks)
    }
    
    public func unpublishVideoTrack(track: LocalVideoTrack) {
        unpublishMediaTrack(track: track, publications: &videoTracks)
    }
    
    public func unpublishDataTrack(track: LocalDataTrack) {
        guard let pubIndex = dataTracks.firstIndex(where: { $0.track === track })  else {
            print("local participant --- track was not published with name: \(track.name)")
            return
        }
        
        let publication = dataTracks[pubIndex] as! LocalDataTrackPublication
        publication.dataTrack?.rtcTrack?.close()
        dataTracks.remove(at: pubIndex)
    }
    
    func setEncodingParameters(parameters: EncodingParameters) {
        
    }
    
    private func unpublishMediaTrack<T>(track: T, publications: inout [TrackPublication]) where T: Track, T: MediaTrack {
        guard let pubIndex = publications.firstIndex(where: { $0.track === track })  else {
            print("local participant --- track was not published with name: \(track.name)")
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
        
        publications.remove(at: pubIndex)
    }
}
