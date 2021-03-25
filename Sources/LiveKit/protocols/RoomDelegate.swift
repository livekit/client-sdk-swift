//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/8/20.
//

import Foundation

public protocol RoomDelegate {
    func didConnect(room: Room)
    func didDisconnect(room: Room, error: Error?)
    func participantDidConnect(room: Room, participant: RemoteParticipant)
    func participantDidDisconnect(room: Room, participant: RemoteParticipant)
    func didFailToConnect(room: Room, error: Error)
    func isReconnecting(room: Room, error: Error)
    func didReconnect(room: Room)
    func didStartRecording(room: Room)
    func didStopRecording(room: Room)
    func activeSpeakersDidChange(speakers: [Participant], room: Room)
    
    /* Local Participant */
    func didPublishLocalTrack(track: Track)
    func didFailToPublishLocalTrack(error: Error, track: Track)
//    func localParticipant:networkQualityLevelDidChange
    
    /* Remote Participant */
    func didPublishRemoteTrack(publication: RemoteTrackPublication, participant: RemoteParticipant)
    func didUnpublishRemoteTrack(publication: RemoteTrackPublication, particpant: RemoteParticipant)
    
//    func didEnable(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
//    func didDisable(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
//    func didEnable(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
//    func didDisable(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
    
    func didSubscribe(publication: RemoteTrackPublication, participant: RemoteParticipant)
    func didFailToSubscribe(publication: RemoteTrackPublication, error: Error, participant: RemoteParticipant)
    func didUnsubscribe(publication: RemoteTrackPublication, participant: RemoteParticipant)

    func didReceive(data: Data, dataTrack: RemoteDataTrackPublication, participant: RemoteParticipant)
    
//    func switchedOffVideo(track: RemoteVideoTrack, participant: RemoteParticipant)
//    func switchedOnVideo(track: RemoteVideoTrack, participant: RemoteParticipant)
//    func networkQualityDidChange(networkQualityLevel: NetworkQualityLevel, participant: remoteParticipant)
//    func didChangePublishPriority(videoTrack: RemoteVideoTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
//    func didChangePublishPriority(audioTrack: RemoteAudioTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
//    func didChangePublishPriority(dataTrack: RemoteDataTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
}
