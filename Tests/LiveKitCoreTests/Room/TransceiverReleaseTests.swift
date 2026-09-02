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

    /// Publishing and unpublishing a track repeatedly must stop every send transceiver, freeing
    /// its media channel, and the connection must still be able to publish afterwards.
    ///
    /// Real-time frame playout is intentionally not asserted: it depends on the host audio
    /// device, which is orthogonal to transceiver release and wedges under heavy test churn.
    @Test(.tags(.e2e), arguments: MediaKind.allCases, [false, true])
    func publishUnpublishCycles(kind: MediaKind, singlePeerConnection: Bool) async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(singlePeerConnection: singlePeerConnection, canPublish: true),
            RoomTestingOptions(singlePeerConnection: singlePeerConnection, canSubscribe: true),
        ]) { rooms in
            let publisherRoom = rooms[0]
            let subscriberRoom = rooms[1]

            let publisher = try #require(publisherRoom._state.transport?.publisher)
            // In single PC mode the shared connection already carries recv transceivers for the
            // pre-created audio + video media sections; everything the loop adds must be released.
            let baseline = await publisher.unstoppedTransceiverCount

            let track = await kind.makeLocalTrack()
            let feeder = ((track as? LocalVideoTrack)?.capturer as? BufferCapturer)?.startFeedingFrames(dimensions: .h720_169)
            defer { feeder?.cancel() }

            for _ in 0 ..< 20 {
                let publication = try await publish(track, on: publisherRoom.localParticipant)
                try await publisherRoom.localParticipant.unpublish(publication: publication)
            }

            let unstopped = await publisher.unstoppedTransceiverCount
            #expect(unstopped == baseline, "Expected every published transceiver stopped, found \(unstopped - baseline) unstopped")

            // A fresh publish must still reach the subscriber after all the stop/release churn.
            let finalPublication = try await publish(track, on: publisherRoom.localParticipant)

            let publisherIdentity = try #require(publisherRoom.localParticipant.identity)
            let remoteParticipant = try #require(subscriberRoom.remoteParticipants[publisherIdentity])

            try await poll(timeout: 30, interval: 0.2, for: "remote \(kind) track subscription after republish") {
                remoteParticipant.trackPublications[finalPublication.sid]?.track != nil
            }
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
