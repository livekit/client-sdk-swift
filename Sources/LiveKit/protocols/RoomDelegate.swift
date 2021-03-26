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
    
    /* All Participants */
    func metadataDidChange(participant: Participant)

    /* Remote Participant */
    func didPublishRemoteTrack(publication: TrackPublication, participant: RemoteParticipant)
    func didUnpublishRemoteTrack(publication: TrackPublication, particpant: RemoteParticipant)
    
    func didMute(publication: TrackPublication, participant: RemoteParticipant)
    func didUnmute(publication: TrackPublication, participant: RemoteParticipant)
//    func didEnable(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
//    func didDisable(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
//    func didEnable(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
//    func didDisable(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
    
    func didSubscribe(track: Track, publication: TrackPublication, participant: RemoteParticipant)
    func didFailToSubscribe(sid: String, error: Error, participant: RemoteParticipant)
    func didUnsubscribe(track: Track, publication: TrackPublication, participant: RemoteParticipant)

    func didReceive(data: Data, dataTrack: TrackPublication, participant: RemoteParticipant)
    
//    func switchedOffVideo(track: RemoteVideoTrack, participant: RemoteParticipant)
//    func switchedOnVideo(track: RemoteVideoTrack, participant: RemoteParticipant)
//    func networkQualityDidChange(networkQualityLevel: NetworkQualityLevel, participant: remoteParticipant)
//    func didChangePublishPriority(videoTrack: RemoteVideoTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
//    func didChangePublishPriority(audioTrack: RemoteAudioTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
//    func didChangePublishPriority(dataTrack: RemoteDataTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
}
