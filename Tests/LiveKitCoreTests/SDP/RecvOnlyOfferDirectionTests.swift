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

/// Does libwebrtc offer `a=inactive` for a transceiver configured `recvonly`?
///
/// It does — but only when the offer sets the legacy `OfferToReceiveAudio`/`OfferToReceiveVideo`
/// option to 0, which makes libwebrtc stop every receiving transceiver. rust-sdks passed it and
/// had to rewrite `a=inactive` to `a=recvonly` on every offer (rust-sdks#1610); client-sdk-android
/// passes it today in `getPublisherOfferConstraints`.
///
/// This SDK never sets it — the only constraint it ever passes is `DtlsSrtpKeyAgreement` — so the
/// rewrite had nothing to fix here. These tests pin that, because the rewrite was not merely
/// redundant: its one real effect was to advertise `recvonly` on sections whose transceiver had
/// been stopped by `removeTrack`, which can never receive anything.
///
/// If a future libwebrtc bump reintroduces `inactive` for receive-only transceivers, these fail
/// and the fix is the offer options, not a munge.
@Suite(.tags(.media))
struct RecvOnlyOfferDirectionTests {
    private final class StubTransportDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
        func transport(_: Transport, didRemoveTrackWithId _: String) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    /// Directions of every RTP section, in section order.
    private func directions(_ sdp: String) -> [SDPDirection?] {
        SDP(parsing: sdp).mediaSections.filter(\.isRTP).map(\.direction)
    }

    private func makeSinglePC() async throws -> Transport {
        try await Transport(config: .liveKitDefault(),
                            target: .publisher,
                            primary: true,
                            singlePCMode: true,
                            delegate: StubTransportDelegate())
    }

    private func addRecvSections(_ transport: Transport, audio: Int, video: Int) async throws {
        try await RTC.run {
            let recv = LKRTCRtpTransceiverInit()
            recv.direction = .recvOnly
            for _ in 0 ..< audio { _ = try transport.addTransceiver(ofType: .audio, transceiverInit: recv) }
            for _ in 0 ..< video { _ = try transport.addTransceiver(ofType: .video, transceiverInit: recv) }
        }
    }

    /// The single PC layout: receive-only sections offered before anything is published.
    @Test func recvOnlyTransceiversOfferRecvOnly() async throws {
        let transport = try await makeSinglePC()
        defer { Task { await transport.close() } }

        try await addRecvSections(transport, audio: 3, video: 3)
        let offer = try await transport.createOffer()

        #expect(directions(offer.sdp) == Array(repeating: .recvonly, count: 6))
    }

    /// The case rust-sdks#1610 reports as persistent: once the remote answers `inactive` for
    /// sections it has no media for, does the next offer revert? With the option unset it does
    /// not — the transceiver stays `recvOnly`, so there is nothing for a munge to repair.
    @Test func offerStaysRecvOnlyAfterRemoteAnswersInactive() async throws {
        let transport = try await makeSinglePC()
        let answerer = try await Transport(config: .liveKitDefault(), target: .subscriber,
                                           primary: false, delegate: StubTransportDelegate())
        defer {
            Task { await transport.close() }
            Task { await answerer.close() }
        }

        try await addRecvSections(transport, audio: 2, video: 2)

        let first = try await transport.createOffer()
        try await transport.set(localDescription: first)
        #expect(directions(first.sdp) == Array(repeating: .recvonly, count: 4))

        // The answerer has no tracks, so it answers every section `inactive` — the same thing
        // the server does for a section it has nothing to send on yet.
        try await answerer.set(remoteDescription: first)
        let answer = try await answerer.createAnswer()
        try await answerer.set(localDescription: answer)
        #expect(directions(answer.sdp) == Array(repeating: .inactive, count: 4))
        try await transport.set(remoteDescription: answer)

        let second = try await transport.createOffer()
        #expect(directions(second.sdp) == Array(repeating: .recvonly, count: 4))
    }

    /// The only section the removed munge actually rewrote. `removeTrack` stops the transceiver,
    /// and a stopped transceiver cannot receive — so offering `recvonly` for it told the server
    /// media would be accepted on a section that could never deliver it.
    @Test func unpublishedSectionStaysInactive() async throws {
        let transport = try await makeSinglePC()
        let answerer = try await Transport(config: .liveKitDefault(), target: .subscriber,
                                           primary: false, delegate: StubTransportDelegate())
        defer {
            Task { await transport.close() }
            Task { await answerer.close() }
        }

        let sender = try await RTC.run { () -> RTCSender in
            let send = LKRTCRtpTransceiverInit()
            send.direction = .sendOnly
            let track = RTC.createVideoTrack(source: RTC.createVideoSource(forScreenShare: false))
            return try RTCSender(transport.addTransceiver(with: track, transceiverInit: send, startBitrateKbps: nil).sender)
        }

        let first = try await transport.createOffer()
        try await transport.set(localDescription: first)
        try await answerer.set(remoteDescription: first)
        let answer = try await answerer.createAnswer()
        try await answerer.set(localDescription: answer)
        try await transport.set(remoteDescription: answer)
        #expect(directions(first.sdp) == [.sendonly])

        try await RTC.run { try transport.remove(track: sender) }

        let second = try await transport.createOffer()
        #expect(directions(second.sdp) == [.inactive],
                "an unpublished section must stay inactive; offering recvonly on a stopped transceiver invites media it cannot receive")
    }
}
