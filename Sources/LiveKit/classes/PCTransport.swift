//
//  PeerConnectionTransport.swift
//
//
//  Created by Russell D'Sa on 2/14/21.
//

import Foundation
import Promises
import WebRTC

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

    @discardableResult
    public func addIceCandidate(_ candidate: RTCIceCandidate) -> Promise<Void> {

        return Promise<Void> { complete, fail in

            if self.pc.remoteDescription != nil && !self.restartingIce {

                self.pc.promiseAddIceCandidate(candidate).then {
                    logger.debug("added ICE candidate for \(self.target.rawValue)")
                    complete(())
                }.catch { error in
                    logger.error("could not add ICE candidate: \(error)")
                    fail(error)
                }

            } else {
                logger.debug("queuing ICE candidate: \(candidate.sdp)")
                self.pendingCandidates.append(candidate)
                complete(())
            }
        }
    }

    public func setRemoteDescription(_ sdp: RTCSessionDescription) -> Promise<Void> {

        return Promise<Void> { complete, fail in

            self.pc.promiseSetRemoteDescription(sdp).then {

                for candidate in self.pendingCandidates {
                    // ignore errors here
                    self.pc.promiseAddIceCandidate(candidate)
                }

                self.pendingCandidates.removeAll()
                self.restartingIce = false

                if (self.renegotiate) {
                    self.renegotiate = false
                    try? self.createAndSendOffer()
                }

            }.catch { error in
                logger.error("setRemoteDescription failed: \(error)")
                fail(error)
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
