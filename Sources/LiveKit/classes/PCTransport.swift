//
//  PeerConnectionTransport.swift
//
//
//  Created by Russell D'Sa on 2/14/21.
//

import Foundation
import Promises
import WebRTC
import CoreMedia

typealias PCTransportOnOffer = (RTCSessionDescription) -> Void

class PCTransport {
    let target: Livekit_SignalTarget
    let pc: RTCPeerConnection
    private var pendingCandidates: [RTCIceCandidate] = []
    private(set) var restartingIce: Bool = false
    var renegotiate: Bool = false
    var onOffer: PCTransportOnOffer?

    init(config: RTCConfiguration,
         target: Livekit_SignalTarget,
         delegate: RTCPeerConnectionDelegate) throws {

        let pc = RTCEngine.factory.peerConnection(with: config,
                                                  constraints: RTCEngine.connConstraints,
                                                  delegate: delegate)
        guard let pc = pc else {
            throw LiveKitError.webRTC("failed to create peerConnection")
        }

        self.target = target
        self.pc = pc
    }

    func addIceCandidate(candidate: RTCIceCandidate) {
        if pc.remoteDescription != nil && !restartingIce {
            pc.add(candidate) { (error: Error?) -> Void in
                if error != nil {
                    logger.error("could not add ICE candidate: \(error!)")
                } else {
                    logger.debug("added ICE candidate for \(self.target.rawValue)")
                }
            }
        } else {
            logger.debug("queuing ICE candidate: \(candidate.sdp)")
            pendingCandidates.append(candidate)
        }
    }

    func setRemoteDescription(_ sdp: RTCSessionDescription, completionHandler: ((Error?) -> Void)? = nil) {
        pc.setRemoteDescription(sdp) { error in
            if error != nil {
                logger.error("setRemoteDescription failed: \(error!)")
                completionHandler?(error)
                return
            }

            for pendingCandidate in self.pendingCandidates {
                // ignore errors here
                self.pc.add(pendingCandidate) { _ in
                }
            }
            self.pendingCandidates.removeAll()
            self.restartingIce = false

            completionHandler?(nil)

            if (self.renegotiate) {
                self.renegotiate = false
                try? self.createAndSendOffer()
            }
        }
    }

    func createAndSendOffer(constraints: [String: String]? = nil) throws {
        guard let onOffer = onOffer else {
            return
        }

        let isIceRestart = constraints?[kRTCMediaConstraintsIceRestart] == kRTCMediaConstraintsValueTrue

        if (isIceRestart) {
            logger.debug("restarting ICE")
            restartingIce = true
        }

        if (pc.signalingState == .haveLocalOffer) {
            //
            let currentSD = pc.remoteDescription
            if isIceRestart, let currentSD = currentSD {

                pc.setRemoteDescription(currentSD) { error in
                    guard error != nil else {
                        logger.error("setRemoteDescription failed: \(error!)")
                        return
                    }

                    let constraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                          optionalConstraints: nil)

                    self.pc.offer(for: constraints) { sd, error in
                        guard error != nil else {
                            logger.error("createOffer failed: \(error!)")
                            return
                        }

                        guard let sd = sd else {
                            return
                        }

                        self.pc.setLocalDescription(sd) { error in
                            guard error != nil else {
                                logger.error("setLocalDescription failed: \(error!)")
                                return
                            }

                            onOffer(sd)
                        }
                    }
                }
            } else {
                renegotiate = true
            }
        }

    }

    func prepareForIceRestart() {
        restartingIce = true
    }

    func close() {
        pc.close()
    }

}
