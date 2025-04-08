/*
 * Copyright 2025 LiveKit
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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

actor Transport: NSObject, Loggable {
    // MARK: - Types

    typealias OnOfferBlock = (LKRTCSessionDescription) async throws -> Void

    /// Enhanced negotiation state tracking with descriptive cases
    enum NegotiationState: Sendable, CustomStringConvertible {
        case idle
        case inProgress(Task<Void, Error>)
        case waitingForRemoteDescription
        case iceRestarting

        var description: String {
            switch self {
            case .idle:
                return "idle"
            case .inProgress:
                return "inProgress"
            case .waitingForRemoteDescription:
                return "waitingForRemoteDescription"
            case .iceRestarting:
                return "iceRestarting"
            }
        }
    }

    // MARK: - Public

    nonisolated let target: Livekit_SignalTarget
    nonisolated let isPrimary: Bool

    var connectionState: RTCPeerConnectionState {
        _pc.connectionState
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    var localDescription: LKRTCSessionDescription? {
        _pc.localDescription
    }

    var remoteDescription: LKRTCSessionDescription? {
        _pc.remoteDescription
    }

    var signalingState: RTCSignalingState {
        _pc.signalingState
    }

    // MARK: - Private

    private let _delegate = MulticastDelegate<TransportDelegate>(label: "TransportDelegate")
    private let _debounce = Debounce(delay: 0.02) // 20ms

    // Enhanced negotiation state machine and task queue
    private var _negotiationState: NegotiationState = .idle
    private let _negotiationQueue = TaskQueue()

    // Only needed for callback
    private var _onOffer: OnOfferBlock?

    // Forbid direct access to PeerConnection
    private let _pc: LKRTCPeerConnection

    // Use the specialized IceCandidatesQueue
    private lazy var _iceCandidatesQueue = IceCandidatesQueue(peerConnection: _pc)

    init(config: LKRTCConfiguration,
         target: Livekit_SignalTarget,
         primary: Bool,
         delegate: TransportDelegate) throws
    {
        // try create peerConnection
        guard let pc = RTC.createPeerConnection(config, constraints: .defaultPCConstraints) else {
            throw LiveKitError(.webRTC, message: "Failed to create PeerConnection")
        }

        self.target = target
        isPrimary = primary
        _pc = pc

        super.init()
        log()

        _pc.delegate = self
        _delegate.add(delegate: delegate)
    }

    deinit {
        log(nil, .trace)
    }

    /// Public API for negotiation - maintains compatibility with existing code
    /// This method is not throwing and uses debounce for stability
    func negotiate(iceRestart: Bool = false) async {
        log("Negotiation requested with iceRestart: \(iceRestart), current state: \(_negotiationState)")

        // Use the enhanced debounce implementation
        await _debounce.schedule {
            // Execute in a sequential manner using our queue
            do {
                try await self._negotiateImpl(iceRestart: iceRestart)
            } catch {
                self.log("Negotiation implementation failed: \(error)", .error)
            }
        }
    }

    /// Internal implementation with enhanced state handling and improved debugging
    private func _negotiateImpl(iceRestart: Bool = false) async throws {
        log("Starting negotiate implementation with iceRestart: \(iceRestart), state: \(_negotiationState)")

        // Enqueue the negotiation request to ensure sequential processing
        try await _negotiationQueue.enqueue { [weak self] in
            guard let self else { return }

            // Handle current state appropriately
            switch await self._negotiationState {
            case .idle:
                // Can proceed with negotiation
                self.log("State is idle, proceeding with negotiation")
            case let .inProgress(task):
                // Wait for existing negotiation to complete
                self.log("Negotiation already in progress, waiting for completion")
                do {
                    try await task.value
                    self.log("Previous negotiation completed successfully")
                } catch {
                    self.log("Previous negotiation failed: \(error)", .warning)
                    // Continue with new negotiation
                }
            case .waitingForRemoteDescription:
                // Set flag to renegotiate after remote description is set
                self.log("Waiting for remote description, will renegotiate after it's set")
                // Already in the correct state (.waitingForRemoteDescription)
                return
            case .iceRestarting:
                if !iceRestart {
                    // Don't interrupt an ICE restart with a regular negotiation
                    self.log("ICE restart in progress, will renegotiate after completion")
                    await self.updateNegotiationState(.waitingForRemoteDescription)
                    return
                }
                self.log("Continuing with new ICE restart")
            }

            // Create a negotiation task and update state
            let negotiationTask = Task<Void, Error> { [weak self] in
                guard let self else { return }
                do {
                    self.log("Creating and sending offer with iceRestart: \(iceRestart)")
                    try await self.createAndSendOffer(iceRestart: iceRestart)
                    self.log("Offer sent successfully, returning to idle state")
                    await self.updateNegotiationState(.idle)
                } catch {
                    self.log("Failed to create and send offer: \(error)", .error)
                    await self.updateNegotiationState(.idle)
                    throw error
                }
            }

            // Update the state
            self.log("Updating state to inProgress")
            await self.updateNegotiationState(.inProgress(negotiationTask))

            // Now wait for the negotiation to complete
            try await negotiationTask.value
            self.log("Negotiation completed successfully")
        }
    }

    /// Update negotiation state with logging
    private func updateNegotiationState(_ newState: NegotiationState) {
        if _negotiationState.description != newState.description {
            log("Updating negotiation state: \(_negotiationState) -> \(newState)")
        }
        _negotiationState = newState
    }

    func set(onOfferBlock block: @escaping OnOfferBlock) {
        _onOffer = block
    }

    /// Mark transport as restarting ICE and update state
    func setIsRestartingIce() async {
        log("Marking as ICE restarting")
        // Directly update the state machine instead of using a separate flag
        updateNegotiationState(.iceRestarting)
    }

    /// Process an ICE candidate - either add immediately or queue for later
    func add(iceCandidate candidate: IceCandidate) async throws {
        // Only process immediately if we have a remote description and we're not restarting ICE
        let isRestarting = if case .iceRestarting = _negotiationState { true } else { false }
        let shouldProcess = remoteDescription != nil && !isRestarting

        if shouldProcess {
            log("Processing ICE candidate immediately")
        } else {
            log("Queueing ICE candidate for later processing")
        }

        await _iceCandidatesQueue.process(candidate, if: shouldProcess)
    }

    /// Set the remote session description with enhanced state handling
    func set(remoteDescription sd: LKRTCSessionDescription) async throws {
        log("Setting remote description with type: \(sd.type.rawValue), signaling state: \(signalingState.rawValue)")

        // If we're restarting ICE, update state
        if case .iceRestarting = _negotiationState {
            log("In ICE restart mode")
            updateNegotiationState(.iceRestarting)
        }

        // Set the remote description
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _pc.setRemoteDescription(sd) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        log("Remote description set successfully")

        // Process any queued ICE candidates now that we have a remote description
        log("Resuming ICE candidates queue processing")
        await _iceCandidatesQueue.resume()

        // Handle ICE restart completion
        if case .iceRestarting = _negotiationState {
            log("ICE restart completed")
            updateNegotiationState(.idle)
        }

        // Handle renegotiation request that was waiting for remote description
        if case .waitingForRemoteDescription = _negotiationState {
            log("Detected pending renegotiation request, starting negotiation")
            // Set state to idle before starting a new negotiation
            updateNegotiationState(.idle)
            try await createAndSendOffer()
        }
    }

    func set(configuration: LKRTCConfiguration) throws {
        if !_pc.setConfiguration(configuration) {
            throw LiveKitError(.webRTC, message: "Failed to set configuration")
        }
    }

    /// Create and send an offer with improved ICE restart handling and better state management
    func createAndSendOffer(iceRestart: Bool = false) async throws {
        guard let _onOffer else {
            log("_onOffer is nil, cannot send offer", .error)
            return
        }

        // Prepare constraints for ICE restart if needed
        var constraints = [String: String]()
        if iceRestart {
            log("Preparing ICE restart constraints")
            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            updateNegotiationState(.iceRestarting)
        }

        // Check current signaling state to avoid errors
        if signalingState == .haveLocalOffer {
            // If we already have a local offer, we need to wait for the remote answer
            // unless we're doing an ICE restart and have a remote description already
            if !(iceRestart && remoteDescription != nil) {
                log("Already have local offer, waiting for remote description before renegotiating")
                updateNegotiationState(.waitingForRemoteDescription)
                return
            }
        }

        // Special case for ICE restart when we already have a local offer
        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            log("ICE restart with existing local offer - reapplying remote description first")
            try await set(remoteDescription: sd)

            // Perform the negotiation sequence
            log("Creating offer with constraints: \(constraints)")
            let offer = try await createOffer(for: constraints)

            log("Setting local description")
            try await set(localDescription: offer)

            log("Sending offer to signaling server")
            try await _onOffer(offer)

            log("Offer sequence completed successfully")
            return
        }

        // Standard negotiation path - perform the negotiation sequence
        log("Creating offer with constraints: \(constraints)")
        let offer = try await createOffer(for: constraints)

        log("Setting local description")
        try await set(localDescription: offer)

        log("Sending offer to signaling server")
        try await _onOffer(offer)

        log("Offer sequence completed successfully")
    }

    func close() async {
        // prevent debounced negotiate firing
        await _debounce.cancel()

        // Stop listening to delegate
        _pc.delegate = nil
        // Remove all senders (if any)
        for sender in _pc.senders {
            _pc.removeTrack(sender)
        }

        _pc.close()
    }
}

// MARK: - Stats

extension Transport {
    func statistics(for sender: LKRTCRtpSender) async -> LKRTCStatisticsReport {
        await withCheckedContinuation { (continuation: CheckedContinuation<LKRTCStatisticsReport, Never>) in
            _pc.statistics(for: sender) { sd in
                continuation.resume(returning: sd)
            }
        }
    }

    func statistics(for receiver: LKRTCRtpReceiver) async -> LKRTCStatisticsReport {
        await withCheckedContinuation { (continuation: CheckedContinuation<LKRTCStatisticsReport, Never>) in
            _pc.statistics(for: receiver) { sd in
                continuation.resume(returning: sd)
            }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension Transport: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange state: RTCPeerConnectionState) {
        log("[Connect] Transport(\(target)) did update state: \(state.description)")
        _delegate.notify { $0.transport(self, didUpdateState: state) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        _delegate.notify { $0.transport(self, didGenerateIceCandidate: candidate.toLKType()) }
    }

    nonisolated func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {
        log("ShouldNegotiate for \(target)")
        _delegate.notify { $0.transportShouldNegotiate(self) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("type: \(type(of: track)), track.id: \(track.trackId), streams: \(streams.map { "Stream(hash: \($0.hash), id: \($0.streamId), videoTracks: \($0.videoTracks.count), audioTracks: \($0.audioTracks.count))" })")
        _delegate.notify { $0.transport(self, didAddTrack: track, rtpReceiver: rtpReceiver, streams: streams) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove rtpReceiver: LKRTCRtpReceiver) {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("didRemove track: \(track.trackId)")
        _delegate.notify { $0.transport(self, didRemoveTrack: track) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        log("Received data channel \(dataChannel.label) for \(target)")
        _delegate.notify { $0.transport(self, didOpenDataChannel: dataChannel) }
    }

    // The following delegate methods are intentionally empty as we use our custom state machine
    // instead of relying on these individual callbacks for our improved ICE negotiation process

    /// Not used - we track connection state through our state machine
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: RTCIceConnectionState) {}

    /// Not used - we handle media stream removal through other mechanisms
    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}

    /// Not used - we track signaling state directly in our negotiate method
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: RTCSignalingState) {}

    /// Not used - we handle media stream addition through other callbacks
    nonisolated func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}

    /// Not used - we don't need to track ICE gathering state changes
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: RTCIceGatheringState) {}

    /// Not used - our ICE candidate handling focuses on additions not removals
    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
}

// MARK: - Private

private extension Transport {
    func createOffer(for constraints: [String: String]? = nil) async throws -> LKRTCSessionDescription {
        let mediaConstraints = LKRTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
            _pc.offer(for: mediaConstraints) { sd, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sd {
                    continuation.resume(returning: sd)
                } else {
                    continuation.resume(throwing: LiveKitError(.invalidState, message: "No session description and no error were provided."))
                }
            }
        }
    }
}

// MARK: - Internal

extension Transport {
    func createAnswer(for constraints: [String: String]? = nil) async throws -> LKRTCSessionDescription {
        let mediaConstraints = LKRTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
            _pc.answer(for: mediaConstraints) { sd, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sd {
                    continuation.resume(returning: sd)
                } else {
                    continuation.resume(throwing: LiveKitError(.invalidState, message: "No session description and no error were provided."))
                }
            }
        }
    }

    func set(localDescription sd: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _pc.setLocalDescription(sd) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func addTransceiver(with track: LKRTCMediaStreamTrack,
                        transceiverInit: LKRTCRtpTransceiverInit) throws -> LKRTCRtpTransceiver
    {
        guard let transceiver = _pc.addTransceiver(with: track, init: transceiverInit) else {
            throw LiveKitError(.webRTC, message: "Failed to add transceiver")
        }

        return transceiver
    }

    func remove(track sender: LKRTCRtpSender) throws {
        guard _pc.removeTrack(sender) else {
            throw LiveKitError(.webRTC, message: "Failed to remove track")
        }
    }

    func dataChannel(for label: String,
                     configuration: LKRTCDataChannelConfiguration,
                     delegate: LKRTCDataChannelDelegate? = nil) -> LKRTCDataChannel?
    {
        let result = _pc.dataChannel(forLabel: label, configuration: configuration)
        result?.delegate = delegate
        return result
    }
}
