import Foundation
import Promises
import WebRTC
import SwiftProtobuf

typealias TransportOnOffer = (RTCSessionDescription) -> Void

internal class Transport: MulticastDelegate<TransportDelegate> {

    public let target: Livekit_SignalTarget
    public let primary: Bool

    // forbid direct access to PeerConnection
    private let pc: RTCPeerConnection

    private var pendingCandidates: [RTCIceCandidate] = []
    internal var restartingIce: Bool = false
    var renegotiate: Bool = false
    var onOffer: TransportOnOffer?

    public var iceConnectionState: RTCIceConnectionState {
        DispatchQueue.webRTC.sync { pc.iceConnectionState }
    }

    public var remoteDescription: RTCSessionDescription? {
        DispatchQueue.webRTC.sync { pc.remoteDescription }
    }

    public var signalingState: RTCSignalingState {
        DispatchQueue.webRTC.sync { pc.signalingState }
    }

    public var isIceConnected: Bool {
        iceConnectionState.isConnected
    }

    // keep reference to cancel later
    private var debounceWorkItem: DispatchWorkItem?

    // create debounce func
    lazy var negotiate = Utils.createDebounceFunc(wait: 0.1, onCreateWorkItem: { [weak self] workItem in
        self?.debounceWorkItem = workItem
    }, fnc: { [weak self] in
        self?.createAndSendOffer()
    })

    public init(config: RTCConfiguration,
                target: Livekit_SignalTarget,
                primary: Bool,
                delegate: TransportDelegate) throws {

        let factory = Engine.factory
        let create = { factory.peerConnection(with: config,
                                              constraints: RTCMediaConstraints.defaultPCConstraints,
                                              delegate: nil) }
        // try create peerConnection
        guard let pc = DispatchQueue.webRTC.sync(execute: create) else {
            throw EngineError.webRTC("failed to create peerConnection")
        }

        self.target = target
        self.primary = primary
        self.pc = pc

        super.init()
        DispatchQueue.webRTC.sync { pc.delegate = self }
        add(delegate: delegate)
    }

    @discardableResult
    public func addIceCandidate(_ candidate: RTCIceCandidate) -> Promise<Void> {

        if remoteDescription != nil && !restartingIce {
            return addIceCandidatePromise(candidate)
        }

        pendingCandidates.append(candidate)

        return Promise(())
    }

    @discardableResult
    public func setRemoteDescription(_ sd: RTCSessionDescription) -> Promise<Void> {

        self.setRemoteDescriptionPromise(sd).then { _ in
            all(self.pendingCandidates.map { self.addIceCandidatePromise($0) })
        }.then { _ in

            self.pendingCandidates.removeAll()
            self.restartingIce = false

            if self.renegotiate {
                self.renegotiate = false
                return self.createAndSendOffer()
            }

            return Promise(())
        }
    }

    @discardableResult
    func createAndSendOffer(iceRestart: Bool = false) -> Promise<Void> {

        guard let onOffer = onOffer else {
            logger.warning("createAndSendOffer() onOffer is nil")
            return Promise(())
        }

        var constraints = [String: String]()
        if iceRestart {
            logger.debug("[Transport] createAndSendOffer() Restarting ICE...")
            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            restartingIce = true
        }

        if signalingState == .haveLocalOffer, !(iceRestart && remoteDescription != nil) {
            renegotiate = true
            return Promise(())
        }

        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            return setRemoteDescriptionPromise(sd).then { _ in
                negotiateSequence()
            }
        }

        // actually negotiate
        func negotiateSequence() -> Promise<Void> {
            createOffer(for: constraints).then { offer in
                self.setLocalDescription(offer)
            }.then { offer in
                onOffer(offer)
            }
        }

        return negotiateSequence()
    }

    public func close() {
        // prevent debounced negotiate firing
        debounceWorkItem?.cancel()

        DispatchQueue.webRTC.sync {
            // Stop listening to delegate
            pc.delegate = nil
            // Remove all senders (if any)
            for sender in pc.senders {
                pc.removeTrack(sender)
            }
            pc.close()
        }
    }
}

extension RTCIceConnectionState {

    func toString() -> String {
        switch self {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return  "count"
        @unknown default: return "unknown"
        }
    }

    var isConnected: Bool {
        .completed == self || .connected == self
    }
}

// MARK: - RTCPeerConnectionDelegate

extension Transport: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange iceState: RTCIceConnectionState) {

        logger.debug("[RTCPeerConnectionDelegate] did change ice state \(iceState.toString()) for \(target)")
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

// MARK: - Promise methods

extension Transport {

    public func createOffer(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                   optionalConstraints: nil)

        return Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            self.pc.offer(for: mediaConstraints) { sd, error in
                guard let sd = sd else {
                    fail(EngineError.webRTC("Failed to create offer", error))
                    return
                }
                complete(sd)
            }
        }
    }

    public func createAnswer(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                   optionalConstraints: nil)

        return Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            self.pc.answer(for: mediaConstraints) { sd, error in
                guard let sd = sd else {
                    fail(EngineError.webRTC("Failed to create answer", error))
                    return
                }
                complete(sd)
            }
        }
    }

    public func setLocalDescription(_ sd: RTCSessionDescription) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            self.pc.setLocalDescription(sd) { error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to set local description", error))
                    return
                }
                complete(sd)
            }
        }
    }

    private func setRemoteDescriptionPromise(_ sd: RTCSessionDescription) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            self.pc.setRemoteDescription(sd) { error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to set remote description", error))
                    return
                }
                complete(sd)
            }
        }
    }

    private func addIceCandidatePromise(_ candidate: RTCIceCandidate) -> Promise<Void> {

        Promise<Void>(on: .webRTC) { complete, fail in

            self.pc.add(candidate) { error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to add ice candidate", error))
                    return
                }
                complete(())
            }
        }
    }

    public func addTransceiver(with track: RTCMediaStreamTrack,
                               transceiverInit: RTCRtpTransceiverInit) -> Promise<RTCRtpTransceiver> {

        Promise<RTCRtpTransceiver>(on: .webRTC) { complete, fail in

            guard let transceiver = self.pc.addTransceiver(with: track, init: transceiverInit) else {
                fail(EngineError.webRTC("Failed to add transceiver"))
                return
            }

            complete(transceiver)
        }
    }

    public func removeTrack(_ sender: RTCRtpSender) -> Promise<Void> {

        Promise<Void>(on: .webRTC) { complete, fail in

            guard self.pc.removeTrack(sender) else {
                fail(EngineError.webRTC("Failed to removeTrack"))
                return
            }

            complete(())
        }
    }

    public func dataChannel(for label: String,
                            configuration: RTCDataChannelConfiguration,
                            delegate: RTCDataChannelDelegate) -> RTCDataChannel? {

        let result = DispatchQueue.webRTC.sync { pc.dataChannel(forLabel: label,
                                                                configuration: configuration) }
        result?.delegate = delegate
        return result
    }
}
