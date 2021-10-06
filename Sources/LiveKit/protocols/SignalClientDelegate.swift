//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/7/20.
//

import Foundation
import WebRTC

protocol SignalClientDelegate: AnyObject {
    func onSignalJoin(joinResponse: Livekit_JoinResponse)
    func onSignalReconnect()
    func onSignalAnswer(sessionDescription: RTCSessionDescription)
    func onSignalOffer(sessionDescription: RTCSessionDescription)
    func onSignalTrickle(candidate: RTCIceCandidate, target: Livekit_SignalTarget)
    func onSignalLocalTrackPublished(trackPublished: Livekit_TrackPublishedResponse)
    func onSignalParticipantUpdate(updates: [Livekit_ParticipantInfo])
    func onSignalActiveSpeakersChanged(speakers: [Livekit_SpeakerInfo])
    func onSignalClose(reason: String, code: UInt16)
    func onSignalLeave()
    func onSignalRemoteMuteChanged(trackSid: String, muted: Bool)
    func onSignalError(error: Error)
}
