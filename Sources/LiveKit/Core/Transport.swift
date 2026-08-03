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

actor Transport: NSObject, Loggable {
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

    // Track bitrate info for x-google-start-bitrate SDP munging
    private var _trackBitrates: [String: TrackBitrateInfo] = [:]

    struct TrackBitrateInfo {
        let codec: String
        let maxBitrateKbps: Int
    }

    // forbid direct access to PeerConnection
    private let _pc: LKRTCPeerConnection

    private lazy var _iceCandidatesQueue = QueueActor<IceCandidate>(onProcess: { [weak self] iceCandidate in
        guard let self else { return }

        do {
            let rtcCandidate = iceCandidate.toRTCType()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self._pc.add(rtcCandidate) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            log("Failed to add(iceCandidate:) with error: \(error)", .error)
        }
    })

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

    /// Register bitrate info for a track to enable x-google-start-bitrate SDP munging
    func setTrackBitrateInfo(cid: String, codec: String, maxBitrateKbps: Int) {
        _trackBitrates[cid] = TrackBitrateInfo(codec: codec, maxBitrateKbps: maxBitrateKbps)
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
            var sdp = offer.sdp

            if singlePCMode {
                sdp = Self.mungeInactiveToRecvOnlyForMedia(sdp)
            }

            // Apply x-google-start-bitrate for video codecs to prevent initial blurriness
            if !_trackBitrates.isEmpty {
                sdp = mungeStartBitrate(sdp, trackBitrates: _trackBitrates)
            }

            if sdp != offer.sdp {
                offer = RTC.createSessionDescription(type: offer.type, sdp: sdp)
            }

            try await set(localDescription: offer)
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
    static func mungeInactiveToRecvOnlyForMedia(_ sdp: String) -> String {
        let usesCRLF = sdp.contains("\r\n")
        let eol = usesCRLF ? "\r\n" : "\n"
        let lines = sdp.components(separatedBy: usesCRLF ? "\r\n" : "\n")

        var out: [String] = []
        out.reserveCapacity(lines.count)
        var inRTPMediaSection = false

        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("m=") {
                inRTPMediaSection = l.contains("RTP/")
            }
            if inRTPMediaSection, l == "a=inactive" {
                out.append("a=recvonly")
            } else {
                out.append(line)
            }
        }

        var result = out.joined(separator: eol)
        if sdp.hasSuffix(eol), !result.hasSuffix(eol) {
            result.append(eol)
        }
        return result
    }

    /// Start bitrate multiplier for x-google-start-bitrate SDP hint.
    /// Why 90%: Gives ~10% headroom for bandwidth estimation while starting close to target.
    /// Why same for all codecs: Target bitrate already accounts for codec efficiency
    /// (e.g., users set lower targets for VP9/AV1 knowing they're more efficient).
    private static let startBitrateMultiplier = 0.9

    private static let videoCodecs = ["vp8", "vp9", "av1", "h264", "h265"]

    /// Munge SDP to add x-google-start-bitrate for video codecs.
    /// This helps prevent initial video blurriness by starting at a higher bitrate.
    func mungeStartBitrate(_ sdp: String, trackBitrates: [String: TrackBitrateInfo]) -> String {
        guard !trackBitrates.isEmpty else { return sdp }

        let usesCRLF = sdp.contains("\r\n")
        let eol = usesCRLF ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: usesCRLF ? "\r\n" : "\n")

        // Find video codecs and their payload types from a=rtpmap lines
        var codecPayloads: [String: Int] = [:]
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            // a=rtpmap:96 VP8/90000
            if l.hasPrefix("a=rtpmap:") {
                let parts = l.dropFirst("a=rtpmap:".count).split(separator: " ", maxSplits: 1)
                if parts.count == 2,
                   let payload = Int(parts[0])
                {
                    let codecName = String(parts[1]).split(separator: "/").first.map(String.init) ?? ""
                    if Self.videoCodecs.contains(codecName.lowercased()) {
                        codecPayloads[codecName.lowercased()] = payload
                    }
                }
            }
        }

        // Get max bitrate from track bitrates for video codecs
        var maxBitrateKbps: Int = 0
        for (_, info) in trackBitrates {
            if Self.videoCodecs.contains(info.codec.lowercased()) {
                maxBitrateKbps = max(maxBitrateKbps, info.maxBitrateKbps)
            }
        }

        guard maxBitrateKbps > 0 else { return sdp }

        let startBitrateKbps = Int(Double(maxBitrateKbps) * Self.startBitrateMultiplier)

        // Update or add fmtp lines for video codecs
        for (codec, payload) in codecPayloads {
            var fmtpFound = false
            for (idx, line) in lines.enumerated() {
                let l = line.trimmingCharacters(in: .whitespaces)
                // a=fmtp:96 profile-id=0
                if l.hasPrefix("a=fmtp:\(payload) ") || l == "a=fmtp:\(payload)" {
                    fmtpFound = true
                    if !l.contains("x-google-start-bitrate") {
                        lines[idx] = "\(line);x-google-start-bitrate=\(startBitrateKbps)"
                    }
                    break
                }
            }

            // If no fmtp line exists for this codec, add one
            if !fmtpFound {
                // Find the rtpmap line for this codec and insert fmtp after it
                for (idx, line) in lines.enumerated() {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("a=rtpmap:\(payload) "), l.lowercased().contains(codec) {
                        lines.insert("a=fmtp:\(payload) x-google-start-bitrate=\(startBitrateKbps)", at: idx + 1)
                        break
                    }
                }
            }
        }

        var result = lines.joined(separator: eol)
        if sdp.hasSuffix(eol), !result.hasSuffix(eol) {
            result.append(eol)
        }
        return result
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
