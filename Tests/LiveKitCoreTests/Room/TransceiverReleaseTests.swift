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

@testable import LiveKit
import LiveKitWebRTC
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Serialized: the E2E cases share one dev server, and every case shares the process-wide
/// WebRTC factory whose signaling thread the stop/release path blocks on.
@Suite(.serialized, .tags(.media),
       .bug("https://github.com/livekit/client-sdk-swift/issues/1104", "Audio transceivers never released on unpublish"))
struct TransceiverReleaseTests {
    enum MediaKind: CaseIterable, CustomTestStringConvertible {
        case audio, video

        var testDescription: String { "\(self)" }

        func makeRTCTrack() -> LKRTCMediaStreamTrack {
            switch self {
            case .audio: RTC.createAudioTrack(source: RTC.createAudioSource(nil))
            case .video: RTC.createVideoTrack(source: RTC.createVideoSource(forScreenShare: false))
            }
        }

        func makeLocalTrack() async -> LocalTrack {
            switch self {
            case .audio: TestAudioTrack()
            case .video: await LocalVideoTrack.createBufferTrack(name: "camera",
                                                                 source: .camera,
                                                                 options: BufferCaptureOptions(dimensions: .h720_169))
            }
        }
    }

    /// What one publish/unpublish cycle puts on the wire. `.both` is the shape that actually
    /// crashed in the field (https://github.com/webrtc-sdk/webrtc/pull/194#issuecomment-3241616070):
    /// two tracks means two transceiver stops racing one debounced renegotiation, so a stop can
    /// land while an offer is in flight — the precondition for `RemoveStoppedTransceivers()`
    /// evicting a transceiver that still owns its media channel.
    enum Scenario: CaseIterable, CustomTestStringConvertible {
        case audio, video, both

        var testDescription: String { "\(self)" }

        var kinds: [MediaKind] {
            switch self {
            case .audio: [.audio]
            case .video: [.video]
            case .both: MediaKind.allCases
            }
        }

        /// Chosen so `cycles * kinds.count` stays under the SFU's 20 pending-track cap: it only
        /// clears a pending track when that track's media arrives (`addMediaTrack`), and this
        /// loop unpublishes before any RTP can flow — `TestAudioTrack` never produces any — so
        /// every publish leaks a slot for the participant's lifetime and the 21st is rejected
        /// with LIMIT_EXCEEDED. A real push-to-talk app holds the track long enough to clear it.
        var cycles: Int { 18 / kinds.count }
    }

    /// Reproduces the exact interleaving that crashed the SDK before the video-only workaround:
    /// stopping a transceiver out-of-band (as `Transport.releaseTransceiver` does) while a
    /// renegotiation is in flight — the stop lands after its offer is applied but before the
    /// answer is — makes `RemoveStoppedTransceivers()` drop the transceiver from the peer
    /// connection with its media channel still attached. Binaries before `webrtc-sdk/webrtc#194`
    /// (<= 137.7151.04) abort at the last reference release with
    /// `RTC_CHECK(!channel_) << "Missing call to ClearChannel?"`; the current pin must survive.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/issues/420", "Original transceiver leak and SIGABRT report"),
          .bug("https://github.com/livekit/client-sdk-swift/pull/770", "Revert of the first release attempt"),
          .bug("https://github.com/webrtc-sdk/webrtc/pull/194", "Ensure ClearChannel is called"),
          arguments: MediaKind.allCases)
    func stopDuringNegotiationDoesNotCrash(kind: MediaKind) async throws {
        let pc1 = try #require(RTC.peerConnectionFactory.peerConnection(with: .liveKitDefault(),
                                                                        constraints: .defaultPCConstraints,
                                                                        delegate: nil))
        let pc2 = try #require(RTC.peerConnectionFactory.peerConnection(with: .liveKitDefault(),
                                                                        constraints: .defaultPCConstraints,
                                                                        delegate: nil))
        defer { pc1.close(); pc2.close() }

        let sendOnly = LKRTCRtpTransceiverInit()
        sendOnly.direction = .sendOnly

        // Round 1: negotiate track A so its media channel is created and live.
        var transceiverA = try #require(pc1.addTransceiver(with: kind.makeRTCTrack(), init: sendOnly)) as LKRTCRtpTransceiver?
        try await negotiate(from: pc1, to: pc2, applyAnswerToOfferer: true)

        // Round 2: adding track B forces a renegotiation whose offer still carries A's
        // m-section as active. Apply the offer on both sides and produce the answer...
        try #require(pc1.addTransceiver(with: kind.makeRTCTrack(), init: sendOnly) != nil)
        let offer2 = try await offer(pc1)
        try await setLocal(pc1, offer2)
        try await setRemote(pc2, offer2)
        let answer2 = try await answer(pc2)
        try await setLocal(pc2, answer2)

        // ...then stop A out-of-band, mid-negotiation, exactly as unpublish does.
        let senderA = try #require(transceiverA?.sender)
        pc1.removeTrack(senderA)
        transceiverA?.stopInternal()

        // Applying the answer runs RemoveStoppedTransceivers(): A leaves pc1's list while its
        // m-section is still active in both descriptions — the precondition of the crash.
        try await setRemote(pc1, answer2)
        #expect(transceiverA?.isStopped == true)
        #expect(pc1.transceivers.count == 1, "stopped transceiver should have been evicted, leaving only B")

        // Dropping the last reference runs ~RtpTransceiver; a buggy binary aborts here.
        transceiverA = nil
    }

    /// Publishing and unpublishing repeatedly must stop every send transceiver, freeing its
    /// media channel, and the publisher must still work afterwards.
    ///
    /// Unpublishing always goes through `unpublishAll()`: for one track it is the same
    /// `_unpublish` path as `unpublish(publication:)`, and for `.both` it is what races two
    /// stops against one debounced renegotiation.
    ///
    /// Deliberately publisher-only. Asserting delivery to a subscriber adds a second room and a
    /// poll that depend on real playout and on a pre-existing m-line ordering bug when an
    /// audio+video pair is re-published; neither has anything to do with transceiver release.
    @Test(.tags(.e2e), arguments: Scenario.allCases, [false, true])
    func publishUnpublishCycles(scenario: Scenario, singlePeerConnection: Bool) async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(singlePeerConnection: singlePeerConnection, canPublish: true),
        ]) { rooms in
            let participant = rooms[0].localParticipant

            let publisher = try #require(rooms[0]._state.transport?.publisher)
            // In single PC mode the shared connection already carries recv transceivers for the
            // pre-created audio + video media sections; everything the cycles add must be released.
            let baseline = await publisher.unstoppedTransceiverCount

            // A fresh track per kind per cycle, because that is what the repro does:
            // `unpublishAll()` leaves no publication, so the next `setMicrophone`/`setCamera`
            // takes `set(source:enabled:)`'s create-and-publish branch rather than unmuting.
            // Each cycle therefore churns a new media source and track, not just a transceiver.
            for _ in 0 ..< scenario.cycles {
                var feeders: [Task<Void, Never>] = []
                defer { feeders.forEach { $0.cancel() } }

                for kind in scenario.kinds {
                    let track = await kind.makeLocalTrack()
                    if let capturer = (track as? LocalVideoTrack)?.capturer as? BufferCapturer {
                        // `_publish` waits on dimensions before starting the capturer, and a
                        // brand new buffer track has none until it is fed.
                        feeders.append(capturer.startFeedingFrames(dimensions: .h720_169))
                        _ = try await capturer.dimensionsCompleter.wait()
                    }
                    _ = try await publish(track, on: participant)
                }
                await participant.unpublishAll()
            }

            let unstopped = await publisher.unstoppedTransceiverCount
            #expect(unstopped == baseline, "Expected every published transceiver stopped, found \(unstopped - baseline) unstopped")
        }
    }
}

// MARK: - Helpers

private extension TransceiverReleaseTests {
    func publish(_ track: LocalTrack, on participant: LocalParticipant) async throws -> LocalTrackPublication {
        switch track {
        case let audioTrack as LocalAudioTrack: try await participant.publish(audioTrack: audioTrack)
        case let videoTrack as LocalVideoTrack: try await participant.publish(videoTrack: videoTrack)
        default: throw LiveKitError(.invalidState, message: "Unsupported track type \(type(of: track))")
        }
    }

    /// Full offer/answer exchange; optionally applies the answer back to the offerer.
    func negotiate(from offerer: LKRTCPeerConnection, to answerer: LKRTCPeerConnection, applyAnswerToOfferer: Bool) async throws {
        let sdpOffer = try await offer(offerer)
        try await setLocal(offerer, sdpOffer)
        try await setRemote(answerer, sdpOffer)
        let sdpAnswer = try await answer(answerer)
        try await setLocal(answerer, sdpAnswer)
        if applyAnswerToOfferer { try await setRemote(offerer, sdpAnswer) }
    }

    func offer(_ pc: LKRTCPeerConnection) async throws -> LKRTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: .defaultPCConstraints) { resume(continuation, $0, $1) }
        }
    }

    func answer(_ pc: LKRTCPeerConnection) async throws -> LKRTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: .defaultPCConstraints) { resume(continuation, $0, $1) }
        }
    }

    func setLocal(_ pc: LKRTCPeerConnection, _ sd: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sd) { resume(continuation, $0) }
        }
    }

    func setRemote(_ pc: LKRTCPeerConnection, _ sd: LKRTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sd) { resume(continuation, $0) }
        }
    }

    func resume(_ continuation: CheckedContinuation<LKRTCSessionDescription, Error>, _ sd: LKRTCSessionDescription?, _ error: Error?) {
        if let sd { continuation.resume(returning: sd) } else {
            continuation.resume(throwing: error ?? LiveKitError(.invalidState, message: "missing SDP"))
        }
    }

    func resume(_ continuation: CheckedContinuation<Void, Error>, _ error: Error?) {
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
