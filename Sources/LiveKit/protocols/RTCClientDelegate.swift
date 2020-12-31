//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/7/20.
//

import Foundation
import WebRTC

protocol RTCClientDelegate {
    func onJoin(info: Livekit_JoinResponse)
    func onAnswer(sessionDescription: RTCSessionDescription)
    func onTrickle(candidate: RTCIceCandidate)
    func onNegotiate(sessionDescription: RTCSessionDescription)
    func onParticipantUpdate(updates: [Livekit_ParticipantInfo])
    func onClose(reason: String)
    func onError(error: Error)
}
