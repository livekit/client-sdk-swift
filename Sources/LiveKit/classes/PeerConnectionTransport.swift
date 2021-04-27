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

    init(config: RTCConfiguration, delegate: RTCPeerConnectionDelegate) {
        let pc = RTCEngine.factory.peerConnection(with: config,
                                                  constraints: RTCEngine.connConstraints,
                                                  delegate: delegate)
        // this must succeed
        peerConnection = pc!
    }

    func addIceCandidate(candidate: RTCIceCandidate) {
        if peerConnection.remoteDescription != nil {
            peerConnection.add(candidate) { (error: Error?) -> Void in
                if error != nil {
                    logger.error("could not add ICE candidate: \(error!)")
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

            for pendingCandidate in self.pendingCandidates {
                self.peerConnection.add(pendingCandidate) { (error: Error?) -> Void in
                    completionHandler?(error)
                }
            }
            self.pendingCandidates.removeAll()
            completionHandler?(nil)
        }
    }

    func close() {
        peerConnection.close()
    }
}
