//
//  PeerConnectionTransport.swift
//
//
//  Created by Russell D'Sa on 2/14/21.
//

import Foundation
import Promises
import WebRTC
import SwiftProtobuf

typealias PCTransportOnOffer = (RTCSessionDescription) -> Void

class PCTransport: NSObject {
    
    let target: Livekit_SignalTarget
    let primary: Bool

    let pc: RTCPeerConnection
    private var pendingCandidates: [RTCIceCandidate] = []
    private(set) var restartingIce: Bool = false
    var renegotiate: Bool = false
    var onOffer: PCTransportOnOffer?

    // keep reference to cancel later
    private var cancelDebounce: DispatchWorkItem?

    // create debounce func
    lazy var negotiate = Utils.createDebounceFunc(wait: 0.1, onDidCreateWork: { [weak self] cancelFnc in
        self?.cancelDebounce = cancelFnc
    }, fnc: { [weak self] in
        self?.createAndSendOffer()
    })

    init(config: RTCConfiguration, target: Livekit_SignalTarget, primary: Bool) throws {

        // try create peerConnection
        let pc = RTCEngine.factory.peerConnection(with: config,
                                                  constraints: RTCEngine.connConstraints,
                                                  delegate: nil)
        guard let pc = pc else {
            throw EngineError.webRTC("failed to create peerConnection")
        }

        self.target = target
        self.primary = primary
        self.pc = pc

        super.init()
        pc.delegate = self
    }

    deinit {
        //
    }

    public func addIceCandidate(_ candidate: RTCIceCandidate) -> Promise<Void> {

        if pc.remoteDescription != nil && !restartingIce {
            return pc.addAsync(candidate)
        }

        pendingCandidates.append(candidate)

        return Promise(())
    }

    public func setRemoteDescription(_ sd: RTCSessionDescription) -> Promise<Void> {

        self.pc.setRemoteDescriptionAsync(sd).then {
            // add all pending IceCandidates
            all(self.pendingCandidates.map { self.pc.addAsync($0) })
        }.then { _ in

            self.pendingCandidates.removeAll()
            self.restartingIce = false

            if (self.renegotiate) {
                self.renegotiate = false
                return self.createAndSendOffer()
            }

            return Promise(())
        }
    }

    @discardableResult
    func createAndSendOffer(_ constraints: [String: String]? = nil) -> Promise<Void> {

        guard let onOffer = onOffer else {
            return Promise(())
        }

        let isIceRestart = constraints?[kRTCMediaConstraintsIceRestart] == kRTCMediaConstraintsValueTrue

        if (isIceRestart) {
            logger.debug("restarting ICE")
            restartingIce = true
        }

        if pc.signalingState == .haveLocalOffer, !(isIceRestart && pc.remoteDescription != nil) {
            renegotiate = true
            return Promise(())
        }

        // actually negotiate
        func negotiateSequence() -> Promise<Void> {
            //
            pc.offerAsync(for: constraints).then { sd in
                self.pc.setLocalDescriptionAsync(sd).then {
                    onOffer(sd)
                }
            }
        }

        if pc.signalingState == .haveLocalOffer, isIceRestart, let sd = pc.remoteDescription {
            pc.setRemoteDescriptionAsync(sd).then {
                negotiateSequence()
            }
        }

        return negotiateSequence()
    }

    func prepareForIceRestart() {
        restartingIce = true
    }

    func close() {
        // prevent debounced negotiate firing
        cancelDebounce?.cancel()

        // remove all senders
        for sender in pc.senders {
            pc.removeTrack(sender)
        }

        pc.close()
    }

}

extension PCTransport: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange iceState: RTCIceConnectionState) {

        logger.debug("peerConnection iceState didChange: \(iceState) \(target)")
        let event = IceStateUpdatedEvent(target: target, primary: primary, iceState: iceState)
        NotificationCenter.liveKit.send(event: event)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        
        logger.debug("peerConnection didGenerateCnadidate: \(candidate) \(target)")
        let event = IceCandidateEvent(target: target, primary: primary, iceCandidate: candidate)
        NotificationCenter.liveKit.send(event: event)
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        logger.debug("peerConnection shouldNegotiate: \(target)")
        let event = ShouldNegotiateEvent(target: target, primary: primary)
        NotificationCenter.liveKit.send(event: event)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {

        guard let track = rtpReceiver.track else {
            return
        }

        logger.debug("peerConnection received streams: \(target)")
        let event = ReceivedTrackEvent(target: target, primary: primary, track: track, streams: mediaStreams)
        NotificationCenter.liveKit.send(event: event)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
