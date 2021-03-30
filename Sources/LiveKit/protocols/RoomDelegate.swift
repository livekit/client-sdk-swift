//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/8/20.
//

import Foundation

/// RoomDelegate receives room events as well as participant events.
///
/// The only two required delegates are `participantDidConnect` and `participantDidDisconnect`
public protocol RoomDelegate {
    /// Successfully connected to the room
    func didConnect(room: Room)
    
    /// Could not connect to the room
    func didFailToConnect(room: Room, error: Error)
    
    /// Client disconnected from the room unexpectedly
    func didDisconnect(room: Room, error: Error?)
    
    /// When a RemoteParticipant joins after the local participant.
    /// It will not emit events for participants that are already in the room
    func participantDidConnect(room: Room, participant: RemoteParticipant)
    
    /// When a RemoteParticipant leaves after the local participant has joined.
    func participantDidDisconnect(room: Room, participant: RemoteParticipant)
    
    /// TODO
    func isReconnecting(room: Room, error: Error)
    
    /// TODO
    func didReconnect(room: Room)
    
    /// Active speakers changed.
    ///
    /// List of speakers are ordered by their audio level. loudest speakers first. This will include the LocalParticipant too.
    func activeSpeakersDidChange(speakers: [Participant], room: Room)
    
    /* All Participants */
    
    /// Participant's metadata has been changed
    func metadataDidChange(participant: Participant)
    
    /// The participant was muted.
    ///
    /// For the local participant, the callback will be called if setMute was called on the local participant,
    /// or if the server has requested the participant to be muted
    func didMute(publication: TrackPublication, participant: Participant)
    
    /// The participant was unmuted.
    ///
    /// For the local participant, the callback will be called if setMute was called on the local participant,
    /// or if the server has requested the participant to be unmuted
    func didUnmute(publication: TrackPublication, participant: Participant)

    /* Remote Participant */
    
    /// When a new track is published to room after the local participant has joined.
    ///
    /// It will not fire for tracks that are already published
    func didPublishRemoteTrack(publication: RemoteTrackPublication, participant: RemoteParticipant)
    
    /// A RemoteParticipant has unpublished a track
    func didUnpublishRemoteTrack(publication: RemoteTrackPublication, particpant: RemoteParticipant)
    
//    func didEnable(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
//    func didDisable(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
//    func didEnable(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
//    func didDisable(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
    
    /// The LocalParticipant has subscribed to a new track.
    ///
    /// This event will always fire as long as new tracks are ready for use.
    func didSubscribe(track: Track, publication: RemoteTrackPublication, participant: RemoteParticipant)
    
    /// Could not subscribe to a track.
    ///
    /// This is an error state, the subscription can be retried
    func didFailToSubscribe(sid: String, error: Error, participant: RemoteParticipant)
    
    /// A subscribed track is no longer available.
    ///
    /// Clients should listen to this event and handle cleanup
    func didUnsubscribe(track: Track, publication: RemoteTrackPublication, participant: RemoteParticipant)

    /// Data was received on a data track
    func didReceive(data: Data, dataTrack: RemoteTrackPublication, participant: RemoteParticipant)
    
//    func switchedOffVideo(track: RemoteVideoTrack, participant: RemoteParticipant)
//    func switchedOnVideo(track: RemoteVideoTrack, participant: RemoteParticipant)
//    func networkQualityDidChange(networkQualityLevel: NetworkQualityLevel, participant: remoteParticipant)
//    func didChangePublishPriority(videoTrack: RemoteVideoTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
//    func didChangePublishPriority(audioTrack: RemoteAudioTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
//    func didChangePublishPriority(dataTrack: RemoteDataTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
}

public extension RoomDelegate {
    func participantDidConnect(room: Room, participant: RemoteParticipant) {}
    func participantDidDisconnect(room: Room, participant: RemoteParticipant) {}
    func isReconnecting(room: Room, error: Error) {}
    func didReconnect(room: Room) {}
    func activeSpeakersDidChange(speakers: [Participant], room: Room) {}
    func metadataDidChange(participant: Participant) {}
    func didMute(publication: TrackPublication, participant: Participant) {}
    func didUnmute(publication: TrackPublication, participant: Participant) {}
    func didPublishRemoteTrack(publication: RemoteTrackPublication, participant: RemoteParticipant) {}
    func didUnpublishRemoteTrack(publication: RemoteTrackPublication, particpant: RemoteParticipant) {}
    func didSubscribe(track: Track, publication: RemoteTrackPublication, participant: RemoteParticipant) {}
    func didFailToSubscribe(sid: String, error: Error, participant: RemoteParticipant) {}
    func didUnsubscribe(track: Track, publication: RemoteTrackPublication, participant: RemoteParticipant) {}
    func didReceive(data: Data, dataTrack: RemoteTrackPublication, participant: RemoteParticipant) {}
}
