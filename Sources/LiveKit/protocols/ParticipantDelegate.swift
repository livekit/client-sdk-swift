//
//  File.swift
//  
//
//  Created by David Zhao on 3/25/21.
//

import Foundation

public protocol ParticipantDelegate {
    func metadataDidChange(participant: Participant)
    func isSpeakingDidChange(participant: Participant)
    
    func didPublishRemoteTrack(publication: TrackPublication, participant: RemoteParticipant)
    func didUnpublishRemoteTrack(publication: TrackPublication, particpant: RemoteParticipant)
    
    func didMute(publication: TrackPublication, participant: RemoteParticipant)
    func didUnmute(publication: TrackPublication, participant: RemoteParticipant)

    func didSubscribe(track: Track, publication: TrackPublication, participant: RemoteParticipant)
    func didFailToSubscribe(sid: String, error: Error, participant: RemoteParticipant)
    func didUnsubscribe(track: Track, publication: TrackPublication, participant: RemoteParticipant)

    func didReceive(data: Data, dataTrack: TrackPublication, participant: RemoteParticipant)
}
