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

@Suite(.tags(.media))
struct TransportSDPMungeTests {
    /// Session-level `a=inactive`, an inactive RTP audio section, an active video
    /// section, and an inactive non-RTP data channel section.
    private static let offer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=inactive
    a=group:BUNDLE 0 1 2
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:0
    a=rtpmap:111 opus/48000/2
    a=inactive
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=mid:1
    a=rtpmap:96 VP8/90000
    a=sendrecv
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    a=mid:2
    a=inactive
    """.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"

    @Test func convertsInactiveToRecvOnlyInRTPSectionsOnly() {
        let munged = Transport.mungeInactiveToRecvOnlyForMedia(Self.offer)
        let sections = SDP(parsing: munged)

        #expect(sections.mediaSections.map(\.direction) == [.recvonly, .sendrecv, .inactive])
        // Session-level line is not a media direction — must be untouched.
        #expect(sections.sessionLines.contains("a=inactive"))
    }

    @Test func preservesEOLStyleAndTrailingNewline() {
        let munged = Transport.mungeInactiveToRecvOnlyForMedia(Self.offer)

        #expect(munged == Self.offer.replacingOccurrences(of: "a=inactive\r\nm=video", with: "a=recvonly\r\nm=video"))
        #expect(munged.hasSuffix("\r\n"))
    }

    @Test func leavesSDPWithoutInactiveSectionsIdentical() {
        let sdp = Self.offer.replacingOccurrences(of: "a=inactive", with: "a=recvonly")
        #expect(Transport.mungeInactiveToRecvOnlyForMedia(sdp) == sdp)
    }

    /// Two Opus audio sections (one already declaring `stereo=1`, one carrying the
    /// `sprop-stereo=1` substring trap), a video section, and a non-Opus audio section.
    private static let singlePCOffer = """
    v=0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:0
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 minptime=10;useinbandfec=1
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:1
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 sprop-stereo=1
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=mid:2
    a=rtpmap:96 VP8/90000
    m=audio 9 UDP/TLS/RTP/SAVPF 8
    a=mid:3
    a=rtpmap:8 PCMA/8000
    a=fmtp:8 maxptime=40
    """.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"

    /// In single PC mode the offerer is also the receiver, so `stereo=1` (RFC 7587 §7.1)
    /// is declared on every audio section's Opus fmtp — including past the
    /// `sprop-stereo=1` substring trap — while video and non-Opus audio are untouched.
    @Test func declaresStereoOnEveryAudioOpusSection() {
        let munged = Transport.mungeOpusStereoForAllAudio(Self.singlePCOffer)

        #expect(SDP(parsing: munged).mediaSections.flatMap(\.fmtps).map(\.config) == [
            "minptime=10;useinbandfec=1;stereo=1",
            "sprop-stereo=1;stereo=1",
            "maxptime=40",
        ])
    }

    @Test func stereoForAllAudioIsIdempotentAndPreservesUnrelatedSDP() {
        let once = Transport.mungeOpusStereoForAllAudio(Self.singlePCOffer)

        #expect(Transport.mungeOpusStereoForAllAudio(once) == once)
        #expect(Transport.mungeOpusStereoForAllAudio(Self.offer) == Self.offer)
    }

    /// A publisher offer with two video sections sending known tracks (`cam`: H.264 with two
    /// payloads, one lower-cased and already carrying a stale start bitrate, plus VP8 without
    /// an fmtp line and an rtx payload; `share`: VP9 and AV1), a video section whose sender is
    /// not mapped, and an Opus audio section.
    private static let publisherOffer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:0
    a=msid:- mic
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 minptime=10;useinbandfec=1
    a=sendonly
    m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99
    a=mid:1
    a=msid:- cam
    a=rtpmap:96 H264/90000
    a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
    a=rtpmap:97 h264/90000
    a=fmtp:97 packetization-mode=0;x-google-start-bitrate=500;profile-level-id=42e01f
    a=rtpmap:98 VP8/90000
    a=rtpmap:99 rtx/90000
    a=fmtp:99 apt=98
    a=sendonly
    m=video 9 UDP/TLS/RTP/SAVPF 100 101
    a=mid:2
    a=msid:- share
    a=rtpmap:100 VP9/90000
    a=fmtp:100 profile-id=0
    a=rtpmap:101 AV1/90000
    a=sendonly
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=mid:3
    a=msid:- other
    a=rtpmap:96 H264/90000
    a=fmtp:96 packetization-mode=1
    a=sendonly
    """.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"

    /// Each mapped sender's section gains its own start bitrate on every video codec —
    /// matched case-insensitively, replacing a stale value, appended to an existing fmtp line
    /// or inserted as a new one — while rtx, audio and the unmapped section are untouched.
    @Test func declaresStartBitratePerSenderOnEveryVideoCodec() {
        let munged = Transport.mungeVideoStartBitrate(Self.publisherOffer, kbpsBySenderId: ["cam": 1000, "share": 4500])
        let sections = SDP(parsing: munged).mediaSections

        #expect(sections[0].lines == SDP(parsing: Self.publisherOffer).mediaSections[0].lines)
        #expect(sections[1].fmtps.map(\.config) == [
            "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f;x-google-start-bitrate=1000",
            "packetization-mode=0;x-google-start-bitrate=1000;profile-level-id=42e01f",
            "apt=98",
            "x-google-start-bitrate=1000",
        ])
        #expect(sections[1].lines.last == "a=fmtp:98 x-google-start-bitrate=1000")
        #expect(sections[2].fmtps.map(\.config) == ["profile-id=0;x-google-start-bitrate=4500", "x-google-start-bitrate=4500"])
        #expect(sections[3].lines == SDP(parsing: Self.publisherOffer).mediaSections[3].lines)
    }

    @Test func startBitrateIsIdempotentAndPreservesUnrelatedSDP() {
        let once = Transport.mungeVideoStartBitrate(Self.publisherOffer, kbpsBySenderId: ["cam": 1000])

        #expect(Transport.mungeVideoStartBitrate(once, kbpsBySenderId: ["cam": 1000]) == once)
        #expect(once.hasSuffix("\r\n"))
        // Nothing mapped, or no matching sender: byte-identical.
        #expect(Transport.mungeVideoStartBitrate(Self.publisherOffer, kbpsBySenderId: [:]) == Self.publisherOffer)
        #expect(Transport.mungeVideoStartBitrate(Self.publisherOffer, kbpsBySenderId: ["absent": 1000]) == Self.publisherOffer)
        // Sections without an msid line are never matched.
        #expect(Transport.mungeVideoStartBitrate(Self.singlePCOffer, kbpsBySenderId: ["cam": 1000]) == Self.singlePCOffer)
    }

    /// Same numbers as client-sdk-js and rust-sdks: 90% of the target, capped at 1 Mbps unless
    /// the track is a screen share, and no hint at all under 300 kbps.
    @Test func startBitrateFormula() {
        #expect(Transport.startBitrateKbps(targetBps: 2_300_000, isScreenShare: false) == 1000) // 2070, capped
        #expect(Transport.startBitrateKbps(targetBps: 800_000, isScreenShare: false) == 720)
        #expect(Transport.startBitrateKbps(targetBps: 300_000, isScreenShare: false) == 270)
        #expect(Transport.startBitrateKbps(targetBps: 5_000_000, isScreenShare: true) == 4500) // not capped
        #expect(Transport.startBitrateKbps(targetBps: 299_999, isScreenShare: false) == nil)
        #expect(Transport.startBitrateKbps(targetBps: 0, isScreenShare: true) == nil)
    }

    /// Simulcast layers are summed (they are independent streams), inactive layers and layers
    /// without a `maxBitrate` contribute nothing.
    @Test func startBitrateSumsActiveEncodings() {
        let encodings = [(500_000, true), (1_500_000, true), (9_000_000, false)].map { bps, active in
            let encoding = LKRTCRtpEncodingParameters()
            encoding.maxBitrateBps = NSNumber(value: bps)
            encoding.isActive = active
            return encoding
        }

        #expect(Transport.startBitrateKbps(for: encodings, isScreenShare: true) == 1800)
        #expect(Transport.startBitrateKbps(for: encodings, isScreenShare: false) == 1000)
        #expect(Transport.startBitrateKbps(for: [LKRTCRtpEncodingParameters()], isScreenShare: false) == nil)
        #expect(Transport.startBitrateKbps(for: [], isScreenShare: false) == nil)
    }
}
