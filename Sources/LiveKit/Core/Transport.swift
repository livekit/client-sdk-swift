/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import SwiftProtobuf

@_implementationOnly import WebRTC

internal class Transport: MulticastDelegate<TransportDelegate> {

    typealias OnOfferBlock = (LKRTCSessionDescription) async throws -> Void

    // MARK: - Public

    public let target: Livekit_SignalTarget
    public let isPrimary: Bool

    public var isRestartingIce: Bool = false
    public var onOffer: OnOfferBlock?

    public var connectionState: RTCPeerConnectionState {
        DispatchQueue.liveKitWebRTC.sync { _pc.connectionState }
    }

    public var localDescription: LKRTCSessionDescription? {
        DispatchQueue.liveKitWebRTC.sync { _pc.localDescription }
    }

    public var remoteDescription: LKRTCSessionDescription? {
        DispatchQueue.liveKitWebRTC.sync { _pc.remoteDescription }
    }

    public var signalingState: RTCSignalingState {
        DispatchQueue.liveKitWebRTC.sync { _pc.signalingState }
    }

    public var isConnected: Bool {
        connectionState == .connected
    }

    // create debounce func
    public lazy var negotiate = Utils.createDebounceFunc(on: _queue,
                                                         wait: 0.1,
                                                         onCreateWorkItem: { [weak self] workItem in
                                                            self?._debounceWorkItem = workItem
                                                         }, fnc: { [weak self] in
                                                            Task { [weak self] in
                                                                try await self?.createAndSendOffer()
                                                            }
                                                         })

    // MARK: - Private

    private let _queue = DispatchQueue(label: "LiveKitSDK.transport", qos: .default)

    private var _reNegotiate: Bool = false

    // forbid direct access to PeerConnection
    private let _pc: LKRTCPeerConnection
    private var _pendingCandidatesQueue = AsyncQueueActor<LKRTCIceCandidate>()

    // keep reference to cancel later
    private var _debounceWorkItem: DispatchWorkItem?

    init(config: LKRTCConfiguration,
         target: Livekit_SignalTarget,
         primary: Bool,
         delegate: TransportDelegate) throws {

        // try create peerConnection
        guard let pc = Engine.createPeerConnection(config,
                                                   constraints: .defaultPCConstraints) else {

            throw EngineError.webRTC(message: "failed to create peerConnection")
        }

        self.target = target
        self.isPrimary = primary
        self._pc = pc

        super.init()
        log()

        DispatchQueue.liveKitWebRTC.sync { pc.delegate = self }
        add(delegate: delegate)
    }

    deinit {
        log()
    }

    func add(iceCandidate candidate: LKRTCIceCandidate) async throws {

        if remoteDescription != nil && !isRestartingIce {
            return try await _pc.add(candidate)
        }

        await _pendingCandidatesQueue.enqueue(candidate)
    }

    func set(remoteDescription sd: LKRTCSessionDescription) async throws {

        try await _pc.setRemoteDescription(sd)

        await _pendingCandidatesQueue.resume { candidate in
            do {
                try await add(iceCandidate: candidate)
            } catch let error {
                log("Failed to add(iceCandidate:) with error: \(error)", .error)
            }
        }

        isRestartingIce = false

        if _reNegotiate {
            _reNegotiate = false
            try await createAndSendOffer()
        }
    }

    func createAndSendOffer(iceRestart: Bool = false) async throws {

        guard let onOffer = onOffer else {
            log("onOffer is nil", .warning)
            return
        }

        var constraints = [String: String]()
        if iceRestart {
            log("Restarting ICE...")
            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            isRestartingIce = true
        }

        if signalingState == .haveLocalOffer, !(iceRestart && remoteDescription != nil) {
            _reNegotiate = true
            return
        }

        // Actually negotiate
        func _negotiateSequence() async throws {
            let offer = try await createOffer(for: constraints)
            try await _pc.setLocalDescription(offer)
            try await onOffer(offer)
        }

        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            try await set(remoteDescription: sd)
            return try await _negotiateSequence()
        }

        try await _negotiateSequence()
    }

    func close() async throws {

        // prevent debounced negotiate firing
        self._debounceWorkItem?.cancel()

        DispatchQueue.liveKitWebRTC.sync {
            // Stop listening to delegate
            self._pc.delegate = nil
            // Remove all senders (if any)
            for sender in self._pc.senders {
                self._pc.removeTrack(sender)
            }

            self._pc.close()
        }
    }
}

// MARK: - Stats

extension Transport {

    func statistics(for sender: LKRTCRtpSender) async -> LKRTCStatisticsReport {
        await _pc.statistics(for: sender)
    }

    func statistics(for receiver: LKRTCRtpReceiver) async -> LKRTCStatisticsReport {
        await _pc.statistics(for: receiver)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension Transport: LKRTCPeerConnectionDelegate {

    internal func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange state: RTCPeerConnectionState) {
        log("did update state \(state) for \(target)")
        notify { $0.transport(self, didUpdate: state) }
    }

    internal func peerConnection(_ peerConnection: LKRTCPeerConnection,
                                 didGenerate candidate: LKRTCIceCandidate) {

        log("Did generate ice candidates \(candidate) for \(target)")
        notify { $0.transport(self, didGenerate: candidate) }
    }

    internal func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        log("ShouldNegotiate for \(target)")
        notify { $0.transportShouldNegotiate(self) }
    }

    internal func peerConnection(_ peerConnection: LKRTCPeerConnection,
                                 didAdd rtpReceiver: LKRTCRtpReceiver,
                                 streams mediaStreams: [LKRTCMediaStream]) {

        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("didAddTrack type: \(type(of: track)), id: \(track.trackId)")
        notify { $0.transport(self, didAddTrack: track, rtpReceiver: rtpReceiver, streams: mediaStreams) }
    }

    internal func peerConnection(_ peerConnection: LKRTCPeerConnection,
                                 didRemove rtpReceiver: LKRTCRtpReceiver) {

        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("didRemove track: \(track.trackId)")
        notify { $0.transport(self, didRemove: track) }
    }

    internal func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        log("Received data channel \(dataChannel.label) for \(target)")
        notify { $0.transport(self, didOpen: dataChannel) }
    }

    internal func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    internal func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    internal func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    internal func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    internal func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    internal func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
}

// MARK: - Private

private extension Transport {

    func createOffer(for constraints: [String: String]? = nil) async throws -> LKRTCSessionDescription {

        let mediaConstraints = LKRTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await _pc.offer(for: mediaConstraints)
    }
}

// MARK: - Internal

internal extension Transport {

    func createAnswer(for constraints: [String: String]? = nil) async throws -> LKRTCSessionDescription {

        let mediaConstraints = LKRTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await _pc.answer(for: mediaConstraints)
    }

    func set(localDescription sd: LKRTCSessionDescription) async throws {
        try await _pc.setLocalDescription(sd)
    }

    func addTransceiver(with track: LKRTCMediaStreamTrack,
                        transceiverInit: LKRTCRtpTransceiverInit) throws -> LKRTCRtpTransceiver {

        guard let transceiver = DispatchQueue.liveKitWebRTC.sync(execute: { _pc.addTransceiver(with: track, init: transceiverInit) }) else {
            throw EngineError.webRTC(message: "Failed to add transceiver")
        }

        return transceiver
    }

    func remove(track sender: LKRTCRtpSender) throws {
        guard DispatchQueue.liveKitWebRTC.sync(execute: { _pc.removeTrack(sender) }) else {
            throw EngineError.webRTC(message: "Failed to remove track")
        }
    }

    func dataChannel(for label: String,
                     configuration: LKRTCDataChannelConfiguration,
                     delegate: LKRTCDataChannelDelegate? = nil) -> LKRTCDataChannel? {

        let result = DispatchQueue.liveKitWebRTC.sync { _pc.dataChannel(forLabel: label, configuration: configuration) }
        result?.delegate = delegate
        return result
    }
}
