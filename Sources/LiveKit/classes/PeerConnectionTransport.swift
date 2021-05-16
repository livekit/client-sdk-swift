//
//  PeerConnectionTransport.swift
//
//
//  Created by Russell D'Sa on 2/14/21.
//

import Foundation
import Promises
import WebRTC

class PeerConnectionTransport {
    var peerConnection: RTCPeerConnection
    var pendingCandidates: [RTCIceCandidate] = []
    let target: Livekit_SignalTarget

    init(config: RTCConfiguration, target: Livekit_SignalTarget, delegate: RTCPeerConnectionDelegate) {
        let pc = RTCEngine.factory.peerConnection(with: config,
                                                  constraints: RTCEngine.connConstraints,
                                                  delegate: delegate)
        self.target = target
        // this must succeed
        peerConnection = pc!
    }

    func addIceCandidate(candidate: RTCIceCandidate) {
        if peerConnection.remoteDescription != nil {
            peerConnection.add(candidate) { (error: Error?) -> Void in
                if error != nil {
                    logger.error("could not add ICE candidate: \(error!)")
                } else {
                    logger.debug("added ICE candidate for \(self.target.rawValue)")
                }
            }
        } else {
            pendingCandidates.append(candidate)
        }
    }

    func setRemoteDescription(_ sdp: RTCSessionDescription, completionHandler: ((Error?) -> Void)? = nil) {
        peerConnection.setRemoteDescription(sdp) { error in
            if error != nil {
                completionHandler?(error)
                return
            }
            completionHandler?(nil)
            for pendingCandidate in self.pendingCandidates {
                // ignore errors here
                self.peerConnection.add(pendingCandidate) { _ in
                }
            }
            self.pendingCandidates.removeAll()
        }
    }

    func close() {
        peerConnection.close()
    }
}
