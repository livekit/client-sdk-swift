/*
 * Copyright 2026 LiveKit
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

// swiftlint:disable file_length

import Foundation

internal import LiveKitWebRTC

@RTC
final class Transport: NSObject, Loggable {
    // MARK: - Types

    typealias OnOfferBlock = @Sendable (LKRTCSessionDescription, UInt32) async throws -> Void

    // MARK: - Public

    nonisolated let target: Livekit_SignalTarget
    nonisolated let isPrimary: Bool
    nonisolated let singlePCMode: Bool

    var connectionState: LKRTCPeerConnectionState {
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

    var signalingState: LKRTCSignalingState {
        _pc.signalingState
    }

    // MARK: - Private

    private let _delegate = MulticastDelegate<TransportDelegate>(label: "TransportDelegate")
    private let _debounce = Debounce(delay: 0.02) // 20ms

    private var _reNegotiate: Bool = false
    private var _onOffer: OnOfferBlock?
    private var _isRestartingIce: Bool = false
    private var _latestOfferId: UInt32 = 0

    // forbid direct access to PeerConnection
    private let _pc: LKRTCPeerConnection

    private lazy var _iceCandidatesQueue = QueueActor<IceCandidate>(onProcess: { [weak self] iceCandidate in
        guard let self else { return }

        do {
            try await add(rtcCandidate: iceCandidate.toRTCType())
        } catch {
            log("Failed to add(iceCandidate:) with error: \(error)", .error)
        }
    })

    private func add(rtcCandidate: LKRTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _pc.add(rtcCandidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    init(config: LKRTCConfiguration,
         target: Livekit_SignalTarget,
         primary: Bool,
         singlePCMode: Bool = false,
         delegate: TransportDelegate) throws
    {
        // try create peerConnection
        guard let pc = RTC.createPeerConnection(config, constraints: .defaultPCConstraints) else {
            // log("[WebRTC] Failed to create PeerConnection", .error)
            throw LiveKitError(.webRTC, message: "Failed to create PeerConnection")
        }

        self.target = target
        isPrimary = primary
        self.singlePCMode = singlePCMode
        _pc = pc

        super.init()
        log()

        _pc.delegate = self
        _delegate.add(delegate: delegate)
    }

    func negotiate(force: Bool = false) async throws {
        if force {
            // Cancel any pending debounced negotiation; this call supersedes it.
            await _debounce.cancel()
            try await createAndSendOffer()
        } else {
            await _debounce.schedule {
                try await self.createAndSendOffer()
            }
        }
    }

    func set(onOfferBlock block: @escaping OnOfferBlock) {
        _onOffer = block
    }

    func setIsRestartingIce() {
        _isRestartingIce = true
    }

    func add(iceCandidate candidate: IceCandidate) async throws {
        await _iceCandidatesQueue.process(candidate, if: remoteDescription != nil && !_isRestartingIce)
    }

    func set(remoteDescription sd: LKRTCSessionDescription, offerId: UInt32) async throws {
        if signalingState != .haveLocalOffer {
            log("Received answer with unexpected signaling state: \(signalingState), expected .haveLocalOffer", .warning)
        }

        if offerId == 0 {
            log("Skipping validation for legacy server (missing offerId), latestOfferId: \(_latestOfferId)", .warning)
        } else if offerId != _latestOfferId {
            throw LiveKitError(.invalidState, message: "OfferId mismatch, expected \(_latestOfferId) but got \(offerId)")
        }

        try await set(remoteDescription: sd)
    }

    func set(remoteDescription sd: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _pc.setRemoteDescription(sd) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

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
            log("_onOffer is nil", .error)
            return
        }

        var constraints = [String: String]()
        if iceRestart {
            log("Restarting ICE...")
            constraints[kLKRTCMediaConstraintsIceRestart] = kLKRTCMediaConstraintsValueTrue
            _isRestartingIce = true
        }

        if signalingState == .haveLocalOffer, !(iceRestart && remoteDescription != nil) {
            _reNegotiate = true
            return
        }

        // Actually negotiate
        func _negotiateSequence() async throws {
            _latestOfferId += 1
            var offer = try await createOffer(for: constraints)
            // The direction rewrite is required to receive media in single PC mode; the
            // stereo preference is optional and must be the one dropped on rejection.
            offer = try await set(localDescription: offer, munging: singlePCMode
                ? [Self.mungeInactiveToRecvOnlyForMedia, Self.mungeOpusStereoForAllAudio]
                : [])
            try await _onOffer(offer, _latestOfferId)
        }

        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            _reNegotiate = false // Clear flag to prevent double offer
            try await set(remoteDescription: sd)
            return try await _negotiateSequence()
        }

        try await _negotiateSequence()
    }

    func close() async {
        // prevent debounced negotiate firing
        await _debounce.cancel()

        // Stop listening to delegate
        _pc.delegate = nil

        // Do not call removeTrack before close — it nulls sender tracks and
        // changes transceiver directions, causing Close() to skip ClearSend/
        // DetachTrack in its StopTransceiverProcedure and hit edge cases in
        // the worker-thread teardown (ICE use-after-free, AVAudioEngine
        // deallocation assertion). Close() handles full cleanup on its own.
        _pc.close()
    }
}

// MARK: - SDP Munging

extension Transport {
    /// Munge SDP to change `a=inactive` to `a=recvonly` for RTP media m-lines in single PC mode.
    /// WebRTC can generate inactive direction even when transceivers were configured as recvonly.
    /// Only rewrites RTP m-sections — non-RTP sections (e.g. data channel `m=application`) are preserved.
    nonisolated static func mungeInactiveToRecvOnlyForMedia(_ sdp: String) -> String {
        var document = SDP(parsing: sdp)
        for index in document.mediaSections.indices {
            let section = document.mediaSections[index]
            if section.isRTP, section.direction == .inactive {
                document.mediaSections[index].set(direction: .recvonly)
            }
        }
        return document.write()
    }

    /// Munge an answer to declare `stereo=1` on the Opus fmtp of every section whose
    /// counterpart in `offer` advertises `sprop-stereo=1`.
    ///
    /// Per [RFC 7587 §7.1](https://datatracker.ietf.org/doc/html/rfc7587#section-7.1) `stereo`
    /// is the *receiver's* preference: without it libwebrtc instantiates a mono Opus decoder and
    /// downmixes, regardless of what the sender transmits. `sprop-stereo` states only what the
    /// sender emits, so it does not carry the answerer's preference on its own. This mirrors
    /// `ensureAudioNackAndStereo()` in client-sdk-js.
    ///
    /// Sections are matched by mid rather than by position, and the Opus payload type is
    /// resolved independently in each document, so an answerer that reorders or renumbers
    /// still lands the parameter on the right section.
    nonisolated static func mungeOpusStereo(_ sdp: String, matchingOffer offer: String) -> String {
        let stereoMids = Set(SDP(parsing: offer).mediaSections.compactMap { section -> String? in
            guard section.mediaType == "audio",
                  let mid = section.mid,
                  let payload = section.payload(forCodec: "opus"),
                  section.fmtp(forPayload: payload)?.parameters.contains("sprop-stereo=1") == true
            else { return nil }
            return mid
        })
        guard !stereoMids.isEmpty else { return sdp }

        var document = SDP(parsing: sdp)
        for index in document.mediaSections.indices {
            let section = document.mediaSections[index]
            guard let mid = section.mid, stereoMids.contains(mid),
                  let payload = section.payload(forCodec: "opus") else { continue }
            document.mediaSections[index].appendFmtpParameter("stereo=1", forPayload: payload)
        }
        return document.write()
    }

    /// Munge an answer to accept `nack` feedback for Opus on every section whose
    /// counterpart in `offer` advertises it.
    ///
    /// libwebrtc does not support NACK for audio in its codec capabilities, so its answer
    /// drops the `a=rtcp-fb:<pt> nack` the SFU offers (the SFU offers it when RED is off
    /// for the track) and retransmission never activates — feedback is active only when
    /// both sides agree ([RFC 4585 §4.2](https://datatracker.ietf.org/doc/html/rfc4585#section-4.2)).
    /// This mirrors `ensureAudioNackAndStereo()` in client-sdk-js, with the same
    /// mid-and-payload matching as ``mungeOpusStereo(_:matchingOffer:)``.
    nonisolated static func mungeOpusNack(_ sdp: String, matchingOffer offer: String) -> String {
        let nackMids = Set(SDP(parsing: offer).mediaSections.compactMap { section -> String? in
            guard section.mediaType == "audio",
                  let mid = section.mid,
                  let payload = section.payload(forCodec: "opus"),
                  section.hasRtcpFeedback("nack", forPayload: payload)
            else { return nil }
            return mid
        })
        guard !nackMids.isEmpty else { return sdp }

        var document = SDP(parsing: sdp)
        for index in document.mediaSections.indices {
            let section = document.mediaSections[index]
            guard let mid = section.mid, nackMids.contains(mid),
                  let payload = section.payload(forCodec: "opus") else { continue }
            document.mediaSections[index].appendRtcpFeedback("nack", forPayload: payload)
        }
        return document.write()
    }

    /// Munge a local offer to declare `stereo=1` on the Opus fmtp of every audio section.
    ///
    /// In single PC mode the client is the offerer for its own receive sections, and at
    /// offer time it cannot know which remote publications are stereo — so the receive
    /// preference is declared unconditionally, mirroring client-sdk-js (which munges every
    /// local offer) and rust-sdks (`munge_stereo_for_audio`). Dual-PC offers don't take
    /// this path: receive negotiation happens in the subscriber answer munge above, and a
    /// publisher offer's send-only sections gain nothing from a receive preference.
    nonisolated static func mungeOpusStereoForAllAudio(_ sdp: String) -> String {
        var document = SDP(parsing: sdp)
        for index in document.mediaSections.indices {
            let section = document.mediaSections[index]
            guard section.mediaType == "audio",
                  let payload = section.payload(forCodec: "opus") else { continue }
            document.mediaSections[index].appendFmtpParameter("stereo=1", forPayload: payload)
        }
        return document.write()
    }

    /// Applies `munges` composed left-to-right and sets the result as the local
    /// description. libwebrtc validates munged SDP and rejects some munging types
    /// outright (`IsSdpMungingAllowed`, expanding via field-trial kill switches);
    /// a rejected set leaves the peer connection state untouched, so on rejection
    /// the last munge is dropped and the set retried. Order munges most-required
    /// first: a rejected optional munge then cannot revert the ones before it.
    /// A no-op composition sets `original` directly, so nothing munged is ever
    /// offered to libwebrtc. Returns the description that was applied — the one
    /// to signal, since signalling a rejected munge would advertise parameters
    /// the peer connection was never configured with.
    func set(localDescription original: LKRTCSessionDescription,
             munging munges: [(String) -> String]) async throws -> LKRTCSessionDescription
    {
        let mungedSDP = munges.reduce(original.sdp) { $1($0) }
        guard mungedSDP != original.sdp else {
            try await set(localDescription: original)
            return original
        }
        do {
            let munged = RTC.createSessionDescription(type: original.type, sdp: mungedSDP)
            try await set(localDescription: munged)
            return munged
        } catch {
            log("Munged local description was rejected, dropping the last munge and retrying: \(error)", .warning)
            return try await set(localDescription: original, munging: Array(munges.dropLast()))
        }
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
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange state: LKRTCPeerConnectionState) {
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

    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceConnectionState) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
}

// MARK: - Private

// MARK: - Internal

extension Transport {
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

    func addTransceiver(ofType mediaType: LKRTCRtpMediaType,
                        transceiverInit: LKRTCRtpTransceiverInit) throws -> LKRTCRtpTransceiver
    {
        guard let transceiver = _pc.addTransceiver(of: mediaType, init: transceiverInit) else {
            throw LiveKitError(.webRTC, message: "Failed to add transceiver")
        }

        return transceiver
    }

    func remove(track sender: LKRTCRtpSender) throws {
        guard _pc.removeTrack(sender) else {
            throw LiveKitError(.webRTC, message: "Failed to remove track")
        }

        releaseTransceiver(sender: sender)
    }

    // Try to stop the transceiver and free the resources
    // Workaround: https://groups.google.com/g/discuss-webrtc/c/WDsGuVucBjQ?pli=1
    private func releaseTransceiver(sender: LKRTCRtpSender) {
        if let transceiver = _pc.transceivers.first(where: { $0.sender == sender }),
           transceiver.mediaType == .video, !transceiver.isStopped
        {
            log("Stopping video transceiver", .debug)
            transceiver.stopInternal()
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
