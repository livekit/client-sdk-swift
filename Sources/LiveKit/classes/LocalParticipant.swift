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
    
//    public private(set) var signalingRegion: String?
    
    convenience init(fromInfo info: Livekit_ParticipantInfo, engine: RTCEngine, room: Room) {
        self.init(sid: info.sid)
        updateFromInfo(info: info)
        self.engine = engine
        self.room = room
    }
    
    public func getTrackPublication(sid: String) -> LocalTrackPublication? {
        return tracks[sid] as? LocalTrackPublication
    }
    
    public func publishAudioTrack(track: LocalAudioTrack,
                                  options: LocalTrackPublicationOptions? = nil) -> Promise<LocalTrackPublication> {
        return Promise<LocalTrackPublication> { fulfill, reject in
            if self.localAudioTrackPublications.first(where: { $0.track === track }) != nil {
                reject(TrackError.publishError("This track has already been published."))
                return
            }
            
            let cid = track.mediaTrack.trackId
            do {
                try self.engine?.addTrack(cid: cid, name: track.name, kind: .audio)
                    .then({ trackInfo in
                        let transInit = RTCRtpTransceiverInit()
                        transInit.direction = .sendOnly
                        transInit.streamIds = [self.streamId]
                        
                        let transceiver = self.engine?.publisher?.peerConnection.addTransceiver(with: track.mediaTrack, init: transInit)
                        if transceiver == nil {
                            reject(TrackError.publishError("Nil sender returned from peer connection."))
                            return
                        }
                        
                        let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                        self.addTrack(publication: publication)
                        fulfill(publication)
                    })
            } catch {
                reject(error)
            }
        }
    }
    
    
    public func publishVideoTrack(track: LocalVideoTrack,
                                  options: LocalTrackPublicationOptions? = nil) -> Promise<LocalTrackPublication> {
        return Promise<LocalTrackPublication> { fulfill, reject in
            if self.localVideoTrackPublications.first(where: { $0.track === track }) != nil {
                reject(TrackError.publishError("This track has already been published."))
                return
            }
            do {
                let cid = track.mediaTrack.trackId
                try self.engine?.addTrack(cid: cid, name: track.name, kind: .video)
                    .then({ trackInfo in
                        let transInit = RTCRtpTransceiverInit()
                        transInit.direction = .sendOnly
                        transInit.streamIds = [self.streamId]
                        
                        let transceiver = self.engine?.publisher?.peerConnection.addTransceiver(with: track.mediaTrack, init: transInit)
                        if transceiver == nil {
                            reject(TrackError.publishError("Nil sender returned from peer connection."))
                            return
                        }
                        
                        let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                        self.addTrack(publication: publication)
                        fulfill(publication)
                    })
            } catch {
                reject(error)
            }
        }
    }
    
    public func publishDataTrack(track: LocalDataTrack,
                                 options: LocalTrackPublicationOptions? = nil) -> Promise<LocalTrackPublication> {
        return Promise<LocalTrackPublication> { fulfill, reject in
            if self.localDataTrackPublications.first(where: { $0.track === track }) != nil {
                reject(TrackError.publishError("This track has already been published."))
                return
            }
            do {
                // data track cid isn't ready until peer connection creates it, so we'll use name
                let cid = track.name
                do {
                    try self.engine?.addTrack(cid: cid, name: track.name, kind: .data)
                        .then({ trackInfo in
                            let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                            track.sid = trackInfo.sid
                            
                            let config = RTCDataChannelConfiguration()
                            config.isOrdered = track.options.ordered
                            config.maxPacketLifeTime = track.options.maxPacketLifeTime
                            config.maxRetransmits = track.options.maxRetransmits
                            
                            if let dataChannel = self.engine?.publisher?.peerConnection.dataChannel(forLabel: track.name, configuration: config) {
                                track.dataChannel = dataChannel
                            } else {
                                try self.unpublishTrack(track: track)
                                reject(TrackError.publishError("Could not publish data track"))
                            }
                            
                            publication.track = track
                            self.addTrack(publication: publication)
                            
                            fulfill(publication)
                        })
                } catch {
                    reject(error)
                }
            }
        }
    }
    
    public func unpublishTrack(track: Track) throws {
        guard let sid = track.sid else {
            throw TrackError.invalidTrackState("This track was never published.")
        }
        
        switch track.kind {
        case .audio:
            audioTracks.removeValue(forKey: sid)
        case .video:
            videoTracks.removeValue(forKey: sid)
        case .data:
            dataTracks.removeValue(forKey: sid)
        default:
            return
        }
        let publication = tracks.removeValue(forKey: sid)
        guard publication != nil else {
            throw TrackError.unpublishError("could not find published track for \(sid)")
        }
        track.stop()
        
        guard let pc = self.engine?.publisher?.peerConnection else {
            return
        }
        
        let mediaTrack = track as? MediaTrack
        if mediaTrack != nil {
            for sender in pc.senders {
                if let t = sender.track {
                    if t.isEqual(mediaTrack!.mediaTrack) {
                        pc.removeTrack(sender)
                    }
                }
            }
        }
    }
    
    override func updateFromInfo(info: Livekit_ParticipantInfo) {
        super.updateFromInfo(info: info)

        // detect tracks that have been muted remotely, and apply those changes
        for trackInfo in info.tracks {
            guard let publication = getTrackPublication(sid: trackInfo.sid) else {
                // this is unexpected
                continue
            }
            if trackInfo.muted != publication.muted {
                publication.setMuted(trackInfo.muted)
            }
        }
    }

    func setEncodingParameters(parameters: EncodingParameters) {
        
    }
}
