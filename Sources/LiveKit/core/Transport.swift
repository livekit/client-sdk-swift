import Foundation
import Promises
import WebRTC
import SwiftProtobuf

typealias TransportOnOffer = (RTCSessionDescription) -> Void

internal class Transport: MulticastDelegate<TransportDelegate> {

    let target: Livekit_SignalTarget
    let primary: Bool

    let pc: RTCPeerConnection
    private var pendingCandidates: [RTCIceCandidate] = []
    internal var restartingIce: Bool = false
    var renegotiate: Bool = false
    var onOffer: TransportOnOffer?

    // keep reference to cancel later
    private var debounceWorkItem: DispatchWorkItem?

    // create debounce func
    lazy var negotiate = Utils.createDebounceFunc(wait: 0.1, onCreateWorkItem: { [weak self] workItem in
        self?.debounceWorkItem = workItem
    }, fnc: { [weak self] in
        self?.createAndSendOffer()
    })

    init(config: RTCConfiguration,
         target: Livekit_SignalTarget,
         primary: Bool,
         delegate: TransportDelegate) throws {

        // try create peerConnection
        let pc = Engine.factory.peerConnection(with: config,
                                                  constraints: RTCMediaConstraints.defaultPCConstraints,
                                                  delegate: nil)
        guard let pc = pc else {
            throw EngineError.webRTC("failed to create peerConnection")
        }

        self.target = target
        self.primary = primary
        self.pc = pc

        super.init()
        pc.delegate = self
        add(delegate: delegate)
    }

    deinit {
        //
    }

    @discardableResult
    public func addIceCandidate(_ candidate: RTCIceCandidate) -> Promise<Void> {

        if pc.remoteDescription != nil && !restartingIce {
            return pc.addIceCandidatePromise(candidate)
        }

        pendingCandidates.append(candidate)

        return Promise(())
    }

    @discardableResult
    public func setRemoteDescription(_ sd: RTCSessionDescription) -> Promise<Void> {

        self.pc.setRemoteDescriptionPromise(sd).then { _ in
            all(self.pendingCandidates.map { self.pc.addIceCandidatePromise($0) })
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

        if pc.signalingState == .haveLocalOffer, isIceRestart, let sd = pc.remoteDescription {
            return pc.setRemoteDescriptionPromise(sd).then { _ in
                negotiateSequence()
            }
        }

        // actually negotiate
        func negotiateSequence() -> Promise<Void> {
            pc.createOfferPromise(for: constraints).then { offer in
                self.pc.setLocalDescriptionPromise(offer)
            }.then { offer in
                onOffer(offer)
            }
        }

        return negotiateSequence()
    }

    func close() {
        // prevent debounced negotiate firing
        debounceWorkItem?.cancel()

        // remove all senders, not required ?
        // for sender in pc.senders {
        //    pc.removeTrack(sender)
        // }

        pc.close()
    }

}

extension Transport: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange iceState: RTCIceConnectionState) {

        logger.debug("[RTCPeerConnectionDelegate] did change ice state \(iceState) for \(target)")
        notify { $0.transport(self, didUpdate: iceState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        
        logger.debug("[RTCPeerConnectionDelegate] did generate ice candidates \(candidate) for \(target)")
        notify { $0.transport(self, didGenerate: candidate) }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        logger.debug("[RTCPeerConnectionDelegate] shouldNegotiate for \(target)")
        notify { $0.transportShouldNegotiate(self) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {

        guard let track = rtpReceiver.track else {
            logger.warning("[RTCPeerConnectionDelegate] track is empty for \(target)")
            return
        }

        logger.debug("[RTCPeerConnectionDelegate] Received streams for \(target)")
        notify { $0.transport(self, didAdd: track, streams: mediaStreams) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        logger.debug("[RTCPeerConnectionDelegate] Received data channel \(dataChannel.label) for \(target)")
        notify { $0.transport(self, didOpen: dataChannel) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}
