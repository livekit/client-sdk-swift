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
    func ICEDidConnect()
    func ICEDidReconnect()
    func didAddTrack(track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func didUpdateParticipants(updates: [Livekit_ParticipantInfo])
    func didUpdateSpeakers(speakers: [Livekit_SpeakerInfo])
    func didDisconnect()
    func didFailToConnect(error: Error)
    func didReceive(packet: Livekit_UserPacket, kind: Livekit_DataPacket.Kind)
    func didRemoteMuteChange(trackSid: String, muted: Bool)
}
