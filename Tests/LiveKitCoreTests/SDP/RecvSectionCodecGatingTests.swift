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

/// Does restricting the *receive* sections' codec set restrict what the *sending* section can
/// offer, when they share one BUNDLE group?
///
/// This is the single PC layout: receive sections are preallocated before anything is published,
/// so if their codec list constrained the send section, a device whose decoder lacks a codec
/// could not publish in that codec either — which is what a Jetson port hit with H.265 in
/// rust-sdks. The two SDKs build the same layout on the same libwebrtc, so the answer here is
/// the answer there.
@Suite(.tags(.media))
struct RecvSectionCodecGatingTests {
    private final class StubTransportDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
        func transport(_: Transport, didRemoveTrackWithId _: String) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    /// One video section's identity and the codecs it declares.
    private struct VideoSection {
        let mid: String
        let direction: SDPDirection?
        let codecs: Set<String>
    }

    /// Codecs declared by each video section of `sdp`, in section order. Repair codecs are
    /// dropped: they follow whatever they protect, so they say nothing about what was offered.
    private func videoSections(_ sdp: String) -> [VideoSection] {
        SDP(parsing: sdp).mediaSections
            .filter { $0.mediaType == "video" }
            .map { section in
                let codecs = section.rtpmaps.map { $0.codec.uppercased() }
                    .filter { $0 != "RTX" && $0 != "RED" && $0 != "ULPFEC" }
                return VideoSection(mid: section.mid ?? "?", direction: section.direction, codecs: Set(codecs))
            }
    }

    @Test func receiveSectionCodecsDoNotConstrainTheSendingSection() async throws {
        let transport = try await Transport(config: .liveKitDefault(),
                                            target: .publisher,
                                            primary: true,
                                            delegate: StubTransportDelegate())
        defer { Task { await transport.close() } }

        // Capabilities are built and consumed inside the executor: `LKRTCRtpCodecCapability` is
        // not Sendable, so it cannot cross the hop.
        try await RTC.run {
            let allVideo = RTC.videoSenderCapabilities.codecs
            let vp8Only = allVideo.filter { $0.name.uppercased() == "VP8" || $0.name.uppercased() == "RTX" }
            guard let probe = allVideo.first(where: { $0.name.uppercased() == "H264" }) else {
                Issue.record("this libwebrtc build has no H264 sender capability to probe with")
                return
            }

            // Three receive sections restricted to VP8, standing in for a decoder that supports
            // nothing else — the Jetson case, where H.265 decode is unavailable.
            let receive = LKRTCRtpTransceiverInit()
            receive.direction = .recvOnly
            for _ in 0 ..< 3 {
                let transceiver = try transport.addTransceiver(ofType: .video, transceiverInit: receive)
                try transceiver.setCodecPreferences(vp8Only, error: ())
            }
            // One sending section that prefers the probe codec, as `createSender` does.
            let send = LKRTCRtpTransceiverInit()
            send.direction = .sendOnly
            let sender = try transport.addTransceiver(ofType: .video, transceiverInit: send)
            try sender.setCodecPreferences([probe] + allVideo.filter { $0.name != probe.name }, error: ())
        }

        let offer = try await transport.createOffer()
        let sections = videoSections(offer.sdp)

        let sending = try #require(sections.first { $0.direction == .sendonly })
        let receiving = sections.filter { $0.direction == .recvonly }

        #expect(receiving.count == 3)
        for section in receiving {
            #expect(section.codecs == ["VP8"], "mid \(section.mid) offered \(section.codecs.sorted())")
        }
        #expect(sending.codecs.contains("H264"),
                "sending section offered \(sending.codecs.sorted()) — receive sections gated it")
    }

    /// The order single PC actually uses: the receive sections are negotiated by the offer that
    /// goes out with JOIN, and the sending section is added by a later renegotiation. If the
    /// first description's payload-type map excluded a codec, the question is whether a codec
    /// absent from it can still be introduced by a subsequent offer.
    @Test func aCodecAbsentFromTheFirstOfferCanStillBeAddedLater() async throws {
        let transport = try await Transport(config: .liveKitDefault(),
                                            target: .publisher,
                                            primary: true,
                                            delegate: StubTransportDelegate())
        defer { Task { await transport.close() } }

        try await RTC.run {
            let vp8Only = RTC.videoSenderCapabilities.codecs.filter {
                $0.name.uppercased() == "VP8" || $0.name.uppercased() == "RTX"
            }
            let receive = LKRTCRtpTransceiverInit()
            receive.direction = .recvOnly
            for _ in 0 ..< 3 {
                let transceiver = try transport.addTransceiver(ofType: .video, transceiverInit: receive)
                try transceiver.setCodecPreferences(vp8Only, error: ())
            }
        }

        // First description: receive sections only, no H264 anywhere in it.
        let first = try await transport.createOffer()
        try await transport.set(localDescription: first)
        #expect(!videoSections(first.sdp).contains { $0.codecs.contains("H264") })

        try await RTC.run {
            let allVideo = RTC.videoSenderCapabilities.codecs
            guard let probe = allVideo.first(where: { $0.name.uppercased() == "H264" }) else {
                Issue.record("this libwebrtc build has no H264 sender capability to probe with")
                return
            }
            let send = LKRTCRtpTransceiverInit()
            send.direction = .sendOnly
            let sender = try transport.addTransceiver(ofType: .video, transceiverInit: send)
            try sender.setCodecPreferences([probe] + allVideo.filter { $0.name != probe.name }, error: ())
        }

        let second = try await transport.createOffer()
        let sending = try #require(videoSections(second.sdp).first { $0.direction == .sendonly })

        #expect(sending.codecs.contains("H264"),
                "sending section offered \(sending.codecs.sorted()) — the first offer's codec set gated it")
    }
}
