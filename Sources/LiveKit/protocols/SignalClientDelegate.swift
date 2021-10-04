//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/7/20.
//

import Foundation
import WebRTC

protocol SignalClientDelegate: AnyObject {
    func onJoin(joinResponse: Livekit_JoinResponse)
    func onReconnect()
    func onAnswer(sessionDescription: RTCSessionDescription)
    func onOffer(sessionDescription: RTCSessionDescription)
    func onTrickle(candidate: RTCIceCandidate, target: Livekit_SignalTarget)
    func onLocalTrackPublished(trackPublished: Livekit_TrackPublishedResponse)
    func onParticipantUpdate(updates: [Livekit_ParticipantInfo])
    func onActiveSpeakersChanged(speakers: [Livekit_SpeakerInfo])
    func onClose(reason: String, code: UInt16)
    func onLeave()
    func onRemoteMuteChanged(trackSid: String, muted: Bool)
    func onError(error: Error)
}
