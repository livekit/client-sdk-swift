//
// LiveKit iOS SDK
// https://livekit.io
//

import Foundation
import Promises
import WebRTC
import SwiftProtobuf

typealias TransportOnOffer = (RTCSessionDescription) -> Void

internal class Transport: NSObject, MulticastDelegate {

    typealias DelegateType = TransportDelegate
    internal let delegates = NSHashTable<AnyObject>.weakObjects()

    let target: Livekit_SignalTarget
    let primary: Bool

    let pc: RTCPeerConnection
    private var pendingCandidates: [RTCIceCandidate] = []
    private(set) var restartingIce: Bool = false
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
        let pc = RTCEngine.factory.peerConnection(with: config,
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

    public func addIceCandidate(_ candidate: RTCIceCandidate) -> Promise<Void> {

        if pc.remoteDescription != nil && !restartingIce {
            return pc.addIceCandidatePromise(candidate)
        }

        pendingCandidates.append(candidate)

        return Promise(())
    }

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

        // remove all senders
        for sender in pc.senders {
            pc.removeTrack(sender)
        }

        pc.close()
    }

}


internal protocol TransportDelegate {
    func transport(_ transport: Transport, didUpdate iceState: RTCIceConnectionState)
    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate)
    func transportShouldNegotiate(_ transport: Transport)
    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel)
    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
}

// optional
extension TransportDelegate {
    func transport(_ transport: Transport, didUpdate iceState: RTCIceConnectionState) {}
    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate) {}
    func transportShouldNegotiate(_ transport: Transport) {}
    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {}
    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {}
}

class TransportDelegateClosure: NSObject, TransportDelegate {
    typealias OnIceStateUpdated = (_ transport: Transport, _ iceState: RTCIceConnectionState) -> ()
    let onIceStateUpdated: OnIceStateUpdated?

    init(onIceStateUpdated: OnIceStateUpdated? = nil) {
        self.onIceStateUpdated = onIceStateUpdated
    }

    func transport(_ transport: Transport, didUpdate iceState: RTCIceConnectionState) {
        onIceStateUpdated?(transport, iceState)
    }

    // ...
}


extension Transport: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange iceState: RTCIceConnectionState) {

        logger.debug("peerConnection iceState didChange: \(iceState) \(target)")
//        let event = IceStateUpdatedEvent(target: target, primary: primary, iceState: iceState)
//        NotificationCenter.liveKit.send(event: event)

        notify { $0.transport(self, didUpdate: iceState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        
        logger.debug("peerConnection didGenerateCnadidate: \(candidate) \(target)")
//        let event = IceCandidateEvent(target: target, primary: primary, iceCandidate: candidate)
//        NotificationCenter.liveKit.send(event: event)

        notify { $0.transport(self, didGenerate: candidate) }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        logger.debug("peerConnection shouldNegotiate: \(target)")
//        let event = ShouldNegotiateEvent(target: target, primary: primary)
//        NotificationCenter.liveKit.send(event: event)

        notify { $0.transportShouldNegotiate(self) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {

        guard let track = rtpReceiver.track else {
            return
        }

        logger.debug("peerConnection received streams: \(target)")
//        let event = ReceivedTrackEvent(target: target, primary: primary, track: track, streams: mediaStreams)
//        NotificationCenter.liveKit.send(event: event)

        notify { $0.transport(self, didAdd: track, streams: mediaStreams) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {

        logger.debug("peerConnection received dataChannel: \(target)")
//        let event = DataChannelEvent(target: target, primary: primary, dataChannel: dataChannel)
//        NotificationCenter.liveKit.send(event: event)

        notify { $0.transport(self, didOpen: dataChannel) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}
