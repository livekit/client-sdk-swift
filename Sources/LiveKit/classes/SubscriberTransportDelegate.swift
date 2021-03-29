//
//  SubscriberTransportDelegate.swift
//  
//
//  Created by Russell D'Sa on 2/14/21.
//

import Foundation
import WebRTC

class SubscriberTransportDelegate: PeerConnectionTransportDelegate, RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        engine?.client.sendCandidate(candidate: candidate, target: .subscriber)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track {
            engine?.delegate?.didAddTrack(track: track, streams: mediaStreams)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        switch transceiver.mediaType {
        case .video:
            print("subscriber transport --- peerconn started receiving video")
        case .audio:
            print("subscriber transport --- peerconn started receiving audio")
        case .data:
            print("subscriber transport --- peerconn started receiving data")
        default:
            break
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        engine?.delegate?.didAddDataChannel(channel: dataChannel)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}
