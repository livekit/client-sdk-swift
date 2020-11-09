//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/8/20.
//

import Foundation

protocol RoomDelegate {
    optional func didConnect(room: Room)
    optional func didFailToConnect(room: Room, error: Error)
    optional func isReconnecting(room: Room, error: Error)
    optional func didReconnect(room: Room)
    optional func participantDidConnect(room: Room, participant: Participant)
    optional func participantDidDisconnect(room: Room, participant: Participant)
    optional func didStartRecording(room: Room)
    optional func didStopRecording(room: Room)
    optional func dominantSpeakerDidChange(room: Room, participant: Participant)
}
