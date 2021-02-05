//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/29/20.
//

import Foundation

public protocol RemoteParticipantDelegate: AnyObject {
    func didPublish(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
    func didUnpublish(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
    func didPublish(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
    func didUnpublish(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
    func didPublish(dataTrack: RemoteDataTrackPublication, participant: RemoteParticipant)
    func didUnpublish(dataTrack: RemoteDataTrackPublication, participant: RemoteParticipant)
    
    func didEnable(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
    func didDisable(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
    func didEnable(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
    func didDisable(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
    
    func didSubscribe(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
    func didFailToSubscribe(audioTrack: RemoteAudioTrackPublication, error: Error, participant: RemoteParticipant)
    func didUnsubscribe(audioTrack: RemoteAudioTrackPublication, participant: RemoteParticipant)
    
    func didSubscribe(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
    func didFailToSubscribe(videoTrack: RemoteVideoTrackPublication, error: Error, participant: RemoteParticipant)
    func didUnsubscribe(videoTrack: RemoteVideoTrackPublication, participant: RemoteParticipant)
    
//    func didSubscribe(dataTrack: RemoteDataTrackPublication, participant: RemoteParticipant)
//    func didFailToSubscribe(dataTrack: RemoteDataTrackPublication, error: Error, participant: RemoteParticipant)
//    func didUnsubscribe(dataTrack: RemoteDataTrackPublication, participant: RemoteParticipant)
    
//    func networkQualityDidChange(networkQualityLevel: NetworkQualityLevel, participant: remoteParticipant)
    func switchedOffVideo(track: RemoteVideoTrack, participant: RemoteParticipant)
    func switchedOnVideo(track: RemoteVideoTrack, participant: RemoteParticipant)
//    func didChangePublishPriority(videoTrack: RemoteVideoTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
//    func didChangePublishPriority(audioTrack: RemoteAudioTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
//    func didChangePublishPriority(dataTrack: RemoteDataTrackPublication, priority: PublishPriority, participant: RemoteParticipant)
}
