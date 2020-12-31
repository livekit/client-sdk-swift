//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation
import WebRTC

protocol RTCEngineDelegate {
    func didJoin(response: Livekit_JoinResponse)
    func didAddTrack(track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func didAddDataChannel(channel: RTCDataChannel)
    func didUpdateParticipants(updates: [Livekit_ParticipantInfo])
    func didDisconnect(error: Error?)
}
