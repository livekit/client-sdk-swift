//
//  PublisherTransportDelegate.swift
//
//
//  Created by Russell D'Sa on 2/14/21.
//

import Foundation
import WebRTC

class PublisherTransportDelegate: PeerConnectionTransportDelegate, RTCPeerConnectionDelegate {
    func peerConnection(_: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        logger.debug("sending publisher candidate: \(candidate.sdp)")
        engine?.client.sendCandidate(candidate: candidate, target: .publisher)
    }

    func peerConnectionShouldNegotiate(_: RTCPeerConnection) {
        guard engine != nil, engine?.publisher?.peerConnection.remoteDescription != nil else {
            return
        }
        engine?.negotiate()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange _: RTCIceConnectionState) {
        guard let eng = engine else {
            return
        }
        logger.debug("publisher ICE status: \(peerConnection.iceConnectionState.rawValue)")
        if peerConnection.iceConnectionState == .connected {
            eng.iceState = .connected
        } else if peerConnection.iceConnectionState == .failed {
            eng.iceState = .disconnected
        }
    }

    func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
    func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
}
