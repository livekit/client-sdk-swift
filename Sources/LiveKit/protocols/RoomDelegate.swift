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
}
