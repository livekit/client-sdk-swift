//
//  PublisherTransportDelegate.swift
//  
//
//  Created by Russell D'Sa on 2/14/21.
//

import Foundation
import WebRTC

class PublisherTransportDelegate: PeerConnectionTransportDelegate, RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let eng = engine else {
            return
        }
        
        if eng.rtcConnected {
            eng.client.sendCandidate(candidate: candidate, target: .publisher)
        } else {
            eng.pendingCandidates.append(candidate)
        }
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        guard engine != nil, engine!.rtcConnected else {
            return
        }
        engine?.negotiate()
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        guard let eng = engine else {
            return
        }
        if peerConnection.iceConnectionState == .connected && !eng.iceConnected {
            eng.iceConnected = true
        } else if peerConnection.iceConnectionState == .disconnected {
            eng.iceConnected = false
            eng.delegate?.didDisconnect(reason: "Peer connection disconnected")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
