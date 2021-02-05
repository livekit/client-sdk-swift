//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation
import WebRTC

protocol RTCEngineDelegate: AnyObject {
    func didJoin(response: Livekit_JoinResponse)
    func didAddTrack(track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func didPublishLocalTrack(cid: String, track: Livekit_TrackInfo)
    func didAddDataChannel(channel: RTCDataChannel)
    func didUpdateParticipants(updates: [Livekit_ParticipantInfo])
    func didDisconnect(reason: String, code: UInt16)
    func didFailToConnect(error: Error)
}
