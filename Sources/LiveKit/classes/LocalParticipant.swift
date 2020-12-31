//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation

public class LocalParticipant: Participant {
    public var localAudioTracks: [TrackPublication] { audioTracks }
    public var localVideoTracks: [TrackPublication] { videoTracks }
    public var localDataTracks: [TrackPublication] { dataTracks }
    public private(set) var signalingRegion: String?
    public var delegate: LocalParticipantDelegate?
    
    convenience init(fromInfo info: Livekit_ParticipantInfo) {
        self.init(sid: info.sid, name: info.name)
        self.info = info
    }
    
    func publishAudioTrack(track: LocalAudioTrack,
                           options: LocalTrackPublicationOptions? = LocalTrackPublicationOptions.optionsWithPriority(.standard)) {
        
    }
    
    func publishAudioTrack(track: LocalAudioTrack) {
        publishAudioTrack(track: track, options: nil)
    }
    
    func publishVideoTrack(track: LocalVideoTrack,
                           options: LocalTrackPublicationOptions? = LocalTrackPublicationOptions.optionsWithPriority(.standard)) {
        
    }
    
    func publishVideoTrack(track: LocalVideoTrack) {
        publishVideoTrack(track: track, options: nil)
    }
    
    func publishDataTrack(track: LocalDataTrack,
                           options: LocalTrackPublicationOptions? = LocalTrackPublicationOptions.optionsWithPriority(.standard)) {
        
    }
    
    func publishDataTrack(track: LocalDataTrack) {
        publishDataTrack(track: track, options: nil)
    }
    
    func unpublishAudioTrack(track: LocalAudioTrack) {
    
    }
    
    func unpublishVideoTrack(track: LocalVideoTrack) {
    
    }
    
    func unpublishDataTrack(track: LocalDataTrack) {
    
    }
    
    func setEncodingParameters(parameters: EncodingParameters) {
        
    }
}
