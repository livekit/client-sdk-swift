//
//  SubscriberTransportDelegate.swift
//
//
//  Created by Russell D'Sa on 2/14/21.
//

import Foundation
import WebRTC

class SubscriberTransportDelegate: PeerConnectionTransportDelegate, RTCPeerConnectionDelegate {
    func peerConnection(_: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        try? engine?.client.sendCandidate(candidate: candidate, target: .subscriber)
    }

    func peerConnection(_: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track {
            engine?.delegate?.didAddTrack(track: track, streams: mediaStreams)
        }
    }

    func peerConnection(_: RTCPeerConnection, didStartReceivingOn _: RTCRtpTransceiver) {
        // do nothing
    }
    
    func peerConnection(_: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        logger.debug("subscriber ICE state changed: \(state.rawValue)")
    }

    func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
}
