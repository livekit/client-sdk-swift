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

    public var restartingIce: Bool = false
    public var renegotiate: Bool = false
    public var onOffer: TransportOnOffer?

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
    public lazy var negotiate = Utils.createDebounceFunc(wait: 0.1, onCreateWorkItem: { [weak self] workItem in
        self?.debounceWorkItem = workItem
    }, fnc: { [weak self] in
        self?.createAndSendOffer()
    })

    public init(config: RTCConfiguration,
                target: Livekit_SignalTarget,
                primary: Bool,
                delegate: TransportDelegate) throws {

        // try create peerConnection
        guard let pc = Engine.createPeerConnection(config,
                                                   constraints: .defaultPCConstraints) else {

            throw EngineError.webRTC(message: "failed to create peerConnection")
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

        self.setRemoteDescriptionPromise(sd).then(on: .sdk) { _ in
            all(on: .sdk, self.pendingCandidates.map { self.addIceCandidatePromise($0) })
        }.then(on: .sdk) { _ in

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
    public func createAndSendOffer(iceRestart: Bool = false) -> Promise<Void> {

        guard let onOffer = onOffer else {
            log("onOffer is nil", .warning)
            return Promise(())
        }

        var constraints = [String: String]()
        if iceRestart {
            log("Restarting ICE...")
            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            restartingIce = true
        }

        if signalingState == .haveLocalOffer, !(iceRestart && remoteDescription != nil) {
            renegotiate = true
            return Promise(())
        }

        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            return setRemoteDescriptionPromise(sd).then(on: .sdk) { _ in
                negotiateSequence()
            }
        }

        // actually negotiate
        func negotiateSequence() -> Promise<Void> {
            createOffer(for: constraints).then(on: .sdk) { offer in
                self.setLocalDescription(offer)
            }.then(on: .sdk) { offer in
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

internal extension RTCIceConnectionState {

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

    internal func peerConnection(_ peerConnection: RTCPeerConnection,
                                 didChange iceState: RTCIceConnectionState) {

        log("Did change ice state \(iceState.toString()) for \(target)")
        notify { $0.transport(self, didUpdate: iceState) }
    }

    internal func peerConnection(_ peerConnection: RTCPeerConnection,
                                 didGenerate candidate: RTCIceCandidate) {

        log("Did generate ice candidates \(candidate) for \(target)")
        notify { $0.transport(self, didGenerate: candidate) }
    }

    internal func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        log("ShouldNegotiate for \(target)")
        notify { $0.transportShouldNegotiate(self) }
    }

    internal func peerConnection(_ peerConnection: RTCPeerConnection,
                                 didAdd rtpReceiver: RTCRtpReceiver,
                                 streams mediaStreams: [RTCMediaStream]) {

        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("Received streams for \(target)")
        notify { $0.transport(self, didAdd: track, streams: mediaStreams) }
    }

    internal func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        log("Received data channel \(dataChannel.label) for \(target)")
        notify { $0.transport(self, didOpen: dataChannel) }
    }

    internal func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    internal func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    internal func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    internal func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    internal func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

// MARK: - Promise methods

internal extension Transport {

    // MARK: - Internal

    func createAnswer(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                       optionalConstraints: nil)

            self.pc.answer(for: mediaConstraints) { sd, error in
                guard let sd = sd else {
                    fail(EngineError.webRTC(message: "Failed to create answer", error))
                    return
                }
                complete(sd)
            }
        }
    }

    func setLocalDescription(_ sd: RTCSessionDescription) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            self.pc.setLocalDescription(sd) { error in
                guard error == nil else {
                    fail(EngineError.webRTC(message: "failed to set local description", error))
                    return
                }
                complete(sd)
            }
        }
    }

    func addTransceiver(with track: RTCMediaStreamTrack,
                        transceiverInit: RTCRtpTransceiverInit) -> Promise<RTCRtpTransceiver> {

        Promise<RTCRtpTransceiver>(on: .webRTC) { complete, fail in

            guard let transceiver = self.pc.addTransceiver(with: track, init: transceiverInit) else {
                fail(EngineError.webRTC(message: "Failed to add transceiver"))
                return
            }

            complete(transceiver)
        }
    }

    func removeTrack(_ sender: RTCRtpSender) -> Promise<Void> {

        Promise<Void>(on: .webRTC) { complete, fail in

            guard self.pc.removeTrack(sender) else {
                fail(EngineError.webRTC(message: "Failed to removeTrack"))
                return
            }

            complete(())
        }
    }

    func dataChannel(for label: String,
                     configuration: RTCDataChannelConfiguration,
                     delegate: RTCDataChannelDelegate) -> RTCDataChannel? {

        let result = DispatchQueue.webRTC.sync { pc.dataChannel(forLabel: label,
                                                                configuration: configuration) }
        result?.delegate = delegate
        return result
    }

    // MARK: - Private

    private func createOffer(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription>(on: .webRTC) { complete, fail in

            let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                       optionalConstraints: nil)

            self.pc.offer(for: mediaConstraints) { sd, error in
                guard let sd = sd else {
                    fail(EngineError.webRTC(message: "Failed to create offer", error))
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
                    fail(EngineError.webRTC(message: "failed to set remote description", error))
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
                    fail(EngineError.webRTC(message: "failed to add ice candidate", error))
                    return
                }
                complete(())
            }
        }
    }
}
