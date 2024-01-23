/*
 * Copyright 2024 LiveKit
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

actor Transport: NSObject, Loggable {
    // MARK: - Types

    typealias OnOfferBlock = (LKRTCSessionDescription) async throws -> Void

    // MARK: - Public

    nonisolated let target: Livekit_SignalTarget
    nonisolated let isPrimary: Bool

    nonisolated var connectionState: RTCPeerConnectionState {
        DispatchQueue.liveKitWebRTC.sync { _pc.connectionState }
    }

    nonisolated var isConnected: Bool {
        connectionState == .connected
    }

    nonisolated var localDescription: LKRTCSessionDescription? {
        DispatchQueue.liveKitWebRTC.sync { _pc.localDescription }
    }

    nonisolated var remoteDescription: LKRTCSessionDescription? {
        DispatchQueue.liveKitWebRTC.sync { _pc.remoteDescription }
    }

    nonisolated var signalingState: RTCSignalingState {
        DispatchQueue.liveKitWebRTC.sync { _pc.signalingState }
    }

    // MARK: - Private

    private let _delegates = MulticastDelegate<TransportDelegate>()
    private let _queue = DispatchQueue(label: "LiveKitSDK.transport", qos: .default)
    private let _debounce = Debounce(delay: 0.1)

    private var _reNegotiate: Bool = false
    private var _onOffer: OnOfferBlock?
    private var _isRestartingIce: Bool = false

    // forbid direct access to PeerConnection
    private let _pc: LKRTCPeerConnection

    private lazy var _iceCandidatesQueue = QueueActor<LKRTCIceCandidate>(onProcess: { [weak self] iceCandidate in
        guard let self else { return }

        do {
            try await self._pc.add(iceCandidate)
        } catch {
            self.log("Failed to add(iceCandidate:) with error: \(error)", .error)
        }
    })

    init(config: LKRTCConfiguration,
         target: Livekit_SignalTarget,
         primary: Bool,
         delegate: TransportDelegate) throws
    {
        // try create peerConnection
        guard let pc = Engine.createPeerConnection(config,
                                                   constraints: .defaultPCConstraints)
        else {
            // log("[WebRTC] Failed to create PeerConnection", .error)
            throw LiveKitError(.webRTC, message: "Failed to create PeerConnection")
        }

        self.target = target
        isPrimary = primary
        _pc = pc

        super.init()
        log()

        DispatchQueue.liveKitWebRTC.sync { pc.delegate = self }
        add(delegate: delegate)
    }

    deinit {
        log()
    }

    func negotiate() async {
        await _debounce.schedule {
            try await self.createAndSendOffer()
        }
    }

    func set(onOfferBlock block: @escaping OnOfferBlock) {
        _onOffer = block
    }

    func setIsRestartingIce() {
        _isRestartingIce = true
    }

    func add(iceCandidate candidate: LKRTCIceCandidate) async throws {
        await _iceCandidatesQueue.process(candidate, if: remoteDescription != nil && !_isRestartingIce)
    }

    func set(remoteDescription sd: LKRTCSessionDescription) async throws {
        try await _pc.setRemoteDescription(sd)

        await _iceCandidatesQueue.resume()

        _isRestartingIce = false

        if _reNegotiate {
            _reNegotiate = false
            try await createAndSendOffer()
        }
    }

    func set(configuration: LKRTCConfiguration) throws {
        if !_pc.setConfiguration(configuration) {
            throw LiveKitError(.webRTC, message: "Failed to set configuration")
        }
    }

    func createAndSendOffer(iceRestart: Bool = false) async throws {
        guard let _onOffer else {
            log("_onOffer is nil", .warning)
            return
        }

        var constraints = [String: String]()
        if iceRestart {
            log("Restarting ICE...")
            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            _isRestartingIce = true
        }

        if signalingState == .haveLocalOffer, !(iceRestart && remoteDescription != nil) {
            _reNegotiate = true
            return
        }

        // Actually negotiate
        func _negotiateSequence() async throws {
            let offer = try await createOffer(for: constraints)
            try await _pc.setLocalDescription(offer)
            try await _onOffer(offer)
        }

        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            try await set(remoteDescription: sd)
            return try await _negotiateSequence()
        }

        try await _negotiateSequence()
    }

    func close() async {
        // prevent debounced negotiate firing
        await _debounce.cancel()

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
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange state: RTCPeerConnectionState) {
        log("[Connect] Transport(\(target)) did update state: \(state.description)")
        _delegates.notify { $0.transport(self, didUpdateState: state) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        _delegates.notify { $0.transport(self, didGenerateIceCandidate: candidate) }
    }

    nonisolated func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {
        log("ShouldNegotiate for \(target)")
        _delegates.notify { $0.transportShouldNegotiate(self) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("type: \(type(of: track)), track.id: \(track.trackId), streams: \(streams.map { "Stream(hash: \($0.hash), id: \($0.streamId), videoTracks: \($0.videoTracks.count), audioTracks: \($0.audioTracks.count))" })")
        _delegates.notify { $0.transport(self, didAddTrack: track, rtpReceiver: rtpReceiver, streams: streams) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove rtpReceiver: LKRTCRtpReceiver) {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("didRemove track: \(track.trackId)")
        _delegates.notify { $0.transport(self, didRemoveTrack: track) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        log("Received data channel \(dataChannel.label) for \(target)")
        _delegates.notify { $0.transport(self, didOpenDataChannel: dataChannel) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: RTCIceConnectionState) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: RTCSignalingState) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: RTCIceGatheringState) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
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

extension Transport {
    func createAnswer(for constraints: [String: String]? = nil) async throws -> LKRTCSessionDescription {
        let mediaConstraints = LKRTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await _pc.answer(for: mediaConstraints)
    }

    func set(localDescription sd: LKRTCSessionDescription) async throws {
        try await _pc.setLocalDescription(sd)
    }

    func addTransceiver(with track: LKRTCMediaStreamTrack,
                        transceiverInit: LKRTCRtpTransceiverInit) throws -> LKRTCRtpTransceiver
    {
        guard let transceiver = DispatchQueue.liveKitWebRTC.sync(execute: { _pc.addTransceiver(with: track, init: transceiverInit) }) else {
            throw LiveKitError(.webRTC, message: "Failed to add transceiver")
        }

        return transceiver
    }

    func remove(track sender: LKRTCRtpSender) throws {
        guard DispatchQueue.liveKitWebRTC.sync(execute: { _pc.removeTrack(sender) }) else {
            throw LiveKitError(.webRTC, message: "Failed to remove track")
        }
    }

    func dataChannel(for label: String,
                     configuration: LKRTCDataChannelConfiguration,
                     delegate: LKRTCDataChannelDelegate? = nil) -> LKRTCDataChannel?
    {
        let result = DispatchQueue.liveKitWebRTC.sync { _pc.dataChannel(forLabel: label, configuration: configuration) }
        result?.delegate = delegate
        return result
    }
}

// MARK: - MulticastDelegateProtocol

extension Transport: MulticastDelegateProtocol {
    typealias Delegate = TransportDelegate

    public nonisolated func add(delegate: TransportDelegate) {
        _delegates.add(delegate: delegate)
    }

    public nonisolated func remove(delegate: TransportDelegate) {
        _delegates.remove(delegate: delegate)
    }

    public nonisolated func removeAllDelegates() {
        _delegates.removeAllDelegates()
    }
}
