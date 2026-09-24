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

    /// A local offer that has been signalled but not yet applied with
    /// `setLocalDescription`. See ``createInitialOffer()``.
    private var _pendingInitialOffer: LKRTCSessionDescription?
    private var _onOffer: OnOfferBlock?
    private var _isRestartingIce: Bool = false
    private var _latestOfferId: UInt32 = 0
    /// Start bitrate (kbps) hinted for each video sender, recorded by
    /// ``addTransceiver(with:transceiverInit:startBitrateKbps:)``.
    private var _startBitrateKbpsBySenderId: [String: Int] = [:]
    /// Whether the bandwidth estimator has been seeded with a start bitrate. It is decided once
    /// per peer connection, when the first video is negotiated: setting a start bitrate resets
    /// the current estimate, and libwebrtc keeps the value to reseed after a network route
    /// change. A full reconnect builds a new `Transport`, whose estimator is seeded again.
    private(set) var videoStartBitrateSeed: VideoStartBitrateSeed = .pending

    // forbid direct access to PeerConnection; the box parks its blocking release on deinit
    private let _pcBox: RTCBox<LKRTCPeerConnection>

    @RTC private var _pc: LKRTCPeerConnection { _pcBox.value }

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
            _pc.add(rtcCandidate) { @Sendable error in
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
        _pcBox = RTCBox(pc)

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

    /// Creates the offer that rides along with the JOIN request, *without* applying it.
    ///
    /// `setLocalDescription` is deferred until the answer arrives, because applying it
    /// starts ICE gathering — and at this point the peer connection has only the
    /// client-side configuration, so it would gather without the server's TURN servers
    /// and never produce relay candidates. ``set(remoteDescription:)`` applies the
    /// pending offer once ``set(configuration:)`` has installed them, mirroring
    /// `createInitialOffer` in client-sdk-js and `create_initial_offer` in rust-sdks.
    ///
    /// - Returns: The offer to signal and its id, or `nil` outside single PC mode
    ///   (the dual-PC subscriber-primary flow has the server offer first).
    /// - Note: The munges are applied here and the result is signalled as-is, so unlike
    ///   ``set(localDescription:munging:)`` a munge libwebrtc rejects cannot be dropped
    ///   and retried — the peer has already been told what we offered. Both munges on
    ///   this path are the ones every single PC mode offer already carries.
    func createInitialOffer() async throws -> (offer: LKRTCSessionDescription, offerId: UInt32)? {
        guard singlePCMode else { return nil }

        guard signalingState == .stable else {
            log("Signaling state is \(signalingState), cannot create the initial offer", .warning)
            return nil
        }

        let offer = try await createOffer()
        let mungedSDP = [Self.mungeInactiveToRecvOnlyForMedia, Self.mungeOpusStereoForAllAudio]
            .reduce(offer.sdp) { $1($0) }
        let munged = mungedSDP == offer.sdp ? offer : RTC.createSessionDescription(type: offer.type, sdp: mungedSDP)

        _latestOfferId += 1
        _pendingInitialOffer = munged
        return (munged, _latestOfferId)
    }

    /// Drops an initial offer that will never be answered, so the transport falls back to
    /// ordinary negotiation. Used when the JOIN it was bundled with did not succeed.
    func clearPendingInitialOffer() {
        _pendingInitialOffer = nil
    }

    /// Applies a deferred initial offer, if one is outstanding. Take-once, so callers on
    /// both remote-description paths are safe.
    ///
    /// Cleared before the `await` and not restored if the apply throws. `didReceiveAnswer` only
    /// logs, so the answer is gone either way; keeping the offer would additionally leave
    /// `isAwaitingAnswer` true forever, making every later `createAndSendOffer` a no-op. Dropping
    /// it costs the in-flight negotiation, which the connect timeout and reconnect rebuild
    /// anyway. Same as `take()` in rust-sdks.
    private func applyPendingInitialOffer() async throws {
        guard let pendingInitialOffer = _pendingInitialOffer else { return }
        _pendingInitialOffer = nil

        log("Applying the initial offer deferred from JOIN")
        try await set(localDescription: pendingInitialOffer)
    }

    func setIsRestartingIce() {
        _isRestartingIce = true
    }

    func add(iceCandidate candidate: IceCandidate) async throws {
        await _iceCandidatesQueue.process(candidate, if: remoteDescription != nil && !_isRestartingIce)
    }

    func set(remoteDescription sd: LKRTCSessionDescription, offerId: UInt32) async throws {
        // Validate before mutating anything: applying the deferred offer consumes it and moves
        // the connection to `.haveLocalOffer`, so an answer we are about to reject must not get
        // that far.
        if offerId == 0 {
            log("Skipping validation for legacy server (missing offerId), latestOfferId: \(_latestOfferId)", .warning)
        } else if offerId != _latestOfferId {
            throw LiveKitError(.invalidState, message: "OfferId mismatch, expected \(_latestOfferId) but got \(offerId)")
        }

        // Before the state check: an offer bundled with JOIN leaves the connection
        // `.stable` until its answer arrives.
        try await applyPendingInitialOffer()

        if signalingState != .haveLocalOffer {
            log("Received answer with unexpected signaling state: \(signalingState), expected .haveLocalOffer", .warning)
        }

        try await set(remoteDescription: sd)
    }

    func set(remoteDescription sd: LKRTCSessionDescription) async throws {
        try await applyPendingInitialOffer()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _pc.setRemoteDescription(sd) { @Sendable error in
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

        // A deferred initial offer counts as awaiting an answer even though the
        // connection still reads `.stable`, so a publish racing the JOIN queues a
        // renegotiation instead of offering over the top of it.
        let isAwaitingAnswer = signalingState == .haveLocalOffer || _pendingInitialOffer != nil
        if isAwaitingAnswer, !(iceRestart && remoteDescription != nil) {
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
            // After the offer is out, so a negotiation that fails first does not use up the seed.
            // Media only flows once the answer arrives, so the estimator is still seeded in time.
            applyVideoStartBitrateIfNeeded()
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

        _pendingInitialOffer = nil

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

// MARK: - Video start bitrate

extension Transport {
    /// Largest start bitrate hinted for a non-screen-share track, in kbps. Stops the bandwidth
    /// estimator from opening too aggressively on high-bitrate (e.g. 4K) tracks.
    nonisolated static let maxStartBitrateKbps = 1000

    /// Largest start bitrate hinted for a screen share, in kbps. The start value also restarts
    /// the estimator after a network change and sizes its first probes, for every stream on the
    /// connection, so it stays bounded. 3 Mbps leaves the default 1080p15 screen share (about
    /// 2.8 Mbps) unchanged and limits high frame rate or 4K encodings.
    nonisolated static let maxScreenShareStartBitrateKbps = 3000

    /// libwebrtc's own start bitrate when none is set (`kDefaultStartBitrateBps`), in kbps.
    nonisolated static let defaultStartBitrateKbps = 300

    /// Start bitrate hinted to libwebrtc's bandwidth estimator for a video sender whose encodings
    /// total `targetBps`, or `nil` to leave libwebrtc's default in place.
    ///
    /// Without a hint the estimator starts at ``defaultStartBitrateKbps`` and ramps up, so the
    /// first seconds of a published track are visibly blurry. The hint is 90% of the target
    /// bitrate, which skips most of the ramp and leaves headroom for the estimator to settle.
    /// Camera and other sources are capped at ``maxStartBitrateKbps``. Screen share, whose content
    /// needs the bitrate immediately to be legible, gets the higher
    /// ``maxScreenShareStartBitrateKbps``. A hint below the default would only slow the start
    /// down, so none is given then.
    nonisolated static func startBitrateKbps(targetBps: Int, isScreenShare: Bool) -> Int? {
        let startKbps = Int((Double(targetBps / 1000) * 0.9).rounded())
        guard startKbps >= defaultStartBitrateKbps else { return nil }
        return min(startKbps, isScreenShare ? maxScreenShareStartBitrateKbps : maxStartBitrateKbps)
    }

    /// ``startBitrateKbps(targetBps:isScreenShare:)`` for a sender's encodings. The target is the
    /// sum of the active encodings' `maxBitrate`, since simulcast layers are independent streams
    /// the estimator has to fund together. Encodings without a `maxBitrate` contribute nothing.
    nonisolated static func startBitrateKbps(for encodings: [LKRTCRtpEncodingParameters], isScreenShare: Bool) -> Int? {
        let targetBps = encodings.filter(\.isActive).compactMap { $0.maxBitrateBps?.intValue }.reduce(0, +)
        return startBitrateKbps(targetBps: targetBps, isScreenShare: isScreenShare)
    }

    /// The start bitrate for the whole peer connection: the largest hint among the video senders
    /// that are still sending. A sender whose track was removed no longer counts.
    nonisolated static func connectionStartBitrateKbps(sendingSenderIds: some Sequence<String>,
                                                       kbpsBySenderId: [String: Int]) -> Int?
    {
        sendingSenderIds.compactMap { kbpsBySenderId[$0] }.max()
    }

    enum VideoStartBitrateSeed: Equatable {
        /// No video has been negotiated on the peer connection yet.
        case pending
        /// The estimator was seeded at this start bitrate.
        case seeded(kbps: Int)
        /// The first video had no hint, so the estimator was left alone.
        case skipped
    }

    /// Seeds the bandwidth estimator with ``connectionStartBitrateKbps(sendingSenderIds:kbpsBySenderId:)``
    /// through the peer connection's bitrate API, when the first video is negotiated on the peer
    /// connection. See ``videoStartBitrateSeed``.
    ///
    /// The estimator is shared by every stream the peer connection sends, so the start bitrate is
    /// one value for the connection, not one per track. Setting it through the API instead of as
    /// `x-google-start-bitrate` in the offer leaves the SDP untouched, and does not depend on the
    /// remote answer carrying the fmtp back, which is where libwebrtc reads the SDP hint from.
    ///
    /// Only the first video counts. Before it, audio and received media cannot lift the send
    /// estimate much above libwebrtc's default, since increases are capped at 1.5x the measured
    /// throughput and probes at twice the allocated bitrate, so the seed raises it. Once video is
    /// flowing its own traffic drives the estimate, and a later seed could pull it down.
    func applyVideoStartBitrateIfNeeded() {
        guard videoStartBitrateSeed == .pending else { return }
        let sendingSenderIds = _pc.transceivers
            .filter { $0.mediaType == .video && !$0.isStopped && $0.sender.track != nil }
            .map(\.sender.senderId)
        guard !sendingSenderIds.isEmpty else { return }
        guard let kbps = Self.connectionStartBitrateKbps(sendingSenderIds: sendingSenderIds,
                                                         kbpsBySenderId: _startBitrateKbpsBySenderId)
        else {
            videoStartBitrateSeed = .skipped
            return
        }
        guard _pc.setBweMinBitrateBps(nil, currentBitrateBps: NSNumber(value: kbps * 1000), maxBitrateBps: nil) else {
            log("Failed to seed the bandwidth estimator at \(kbps) kbps", .warning)
            return
        }
        videoStartBitrateSeed = .seeded(kbps: kbps)
        log("Seeded the bandwidth estimator at \(kbps) kbps")
    }
}

// MARK: - Stats

extension Transport {
    /// Statistics for the whole connection, including the selected candidate pair.
    func statistics() async -> LKRTCStatisticsReport {
        await withCheckedContinuation { (continuation: CheckedContinuation<LKRTCStatisticsReport, Never>) in
            _pc.statistics { @Sendable sd in
                continuation.resume(returning: sd)
            }
        }
    }

    func statistics(for sender: RTCSender) async -> LKRTCStatisticsReport {
        let raw = sender.raw
        return await withCheckedContinuation { (continuation: CheckedContinuation<LKRTCStatisticsReport, Never>) in
            _pc.statistics(for: raw) { @Sendable sd in
                continuation.resume(returning: sd)
            }
        }
    }

    func statistics(for receiver: RTCReceiver) async -> LKRTCStatisticsReport {
        let raw = receiver.raw
        return await withCheckedContinuation { (continuation: CheckedContinuation<LKRTCStatisticsReport, Never>) in
            _pc.statistics(for: raw) { @Sendable sd in
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
        // Convert on the signaling thread so the raw candidate never crosses isolation.
        let iceCandidate = candidate.toLKType()
        _delegate.notify { $0.transport(self, didGenerateIceCandidate: iceCandidate) }
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
        let receiver = RTCReceiver(rtpReceiver)
        let mediaTrack = RTCMediaTrack(track)
        // Only the ids travel on: the streams' blocking proxy destructors run here, on the
        // signaling thread, instead of wherever the delegate pipeline drops them.
        let streamIds = streams.map(\.streamId)
        _delegate.notify { $0.transport(self, didAddTrack: mediaTrack, rtpReceiver: receiver, streamIds: streamIds) }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove rtpReceiver: LKRTCRtpReceiver) {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        // Only the id travels on: nothing downstream needs the proxy, and boxing it here would
        // add a release to park for a track that is already gone.
        let trackId = track.trackId
        log("didRemove track: \(trackId)")
        _delegate.notify { $0.transport(self, didRemoveTrackWithId: trackId) }
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
            _pc.offer(for: mediaConstraints) { @Sendable sd, error in
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
            _pc.answer(for: mediaConstraints) { @Sendable sd, error in
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
            _pc.setLocalDescription(sd) { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// `startBitrateKbps` (see ``startBitrateKbps(targetBps:isScreenShare:)``) is recorded against
    /// the new sender before returning, so the negotiation this call triggers already sees it.
    func addTransceiver(with track: LKRTCMediaStreamTrack,
                        transceiverInit: LKRTCRtpTransceiverInit,
                        startBitrateKbps: Int? = nil) throws -> LKRTCRtpTransceiver
    {
        guard let transceiver = _pc.addTransceiver(with: track, init: transceiverInit) else {
            throw LiveKitError(.webRTC, message: "Failed to add transceiver")
        }

        if let startBitrateKbps {
            _startBitrateKbpsBySenderId[transceiver.sender.senderId] = startBitrateKbps
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

    func remove(track sender: RTCSender) throws {
        let raw = sender.raw
        guard _pc.removeTrack(raw) else {
            throw LiveKitError(.webRTC, message: "Failed to remove track")
        }
        _startBitrateKbpsBySenderId.removeValue(forKey: sender.senderId)

        releaseTransceiver(sender: raw)
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
