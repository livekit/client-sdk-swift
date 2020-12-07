//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/8/20.
//

import Foundation

protocol RoomDelegate {
    func didConnect(room: Room)
    func didFailToConnect(room: Room, error: Error)
    func isReconnecting(room: Room, error: Error)
    func didReconnect(room: Room)
    func participantDidConnect(room: Room, participant: Participant)
    func participantDidDisconnect(room: Room, participant: Participant)
    func didStartRecording(room: Room)
    func didStopRecording(room: Room)
    func dominantSpeakerDidChange(room: Room, participant: Participant)
}

extension RoomDelegate {
    func didConnect(room: Room) {
        return
    }
    func didFailToConnect(room: Room, error: Error) {
        return
    }
    func isReconnecting(room: Room, error: Error) {
        return
    }
    func didReconnect(room: Room) {
        return
    }
    func participantDidConnect(room: Room, participant: Participant) {
        return
    }
    func participantDidDisconnect(room: Room, participant: Participant) {
        return
    }
    func didStartRecording(room: Room) {
        return
    }
    func didStopRecording(room: Room) {
        return
    }
    func dominantSpeakerDidChange(room: Room, participant: Participant) {
        return
    }
}
