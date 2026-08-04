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
import Testing

@Suite(.tags(.media))
struct OpusStereoSdpTests {
    private static func sdp(_ body: String) -> String {
        body.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
    }

    /// mid 0 is sent in stereo; mid 1 is Opus but mono; mid 2 is video; mid 3 is a
    /// non-Opus codec that nonetheless carries `sprop-stereo`; the last section
    /// advertises stereo but has no mid to match on.
    private static let offer = sdp("""
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0 1 2 3
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:0
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 minptime=10;useinbandfec=1;sprop-stereo=1
    a=sendonly
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:1
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 minptime=10;useinbandfec=1
    a=sendonly
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=mid:2
    a=rtpmap:96 VP8/90000
    a=sendonly
    m=audio 9 UDP/TLS/RTP/SAVPF 8
    a=mid:3
    a=rtpmap:8 PCMA/8000
    a=fmtp:8 sprop-stereo=1
    a=sendonly
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 sprop-stereo=1
    a=sendonly
    """)

    /// The answer libwebrtc generates for `offer`: same mids and payload types, no
    /// `sprop-stereo` (the subscriber sends nothing), and no `stereo` preference —
    /// which is the bug.
    private static let answer = sdp("""
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0 1 2 3
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:0
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 minptime=10;useinbandfec=1
    a=recvonly
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:1
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 minptime=10;useinbandfec=1
    a=recvonly
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=mid:2
    a=rtpmap:96 VP8/90000
    a=recvonly
    m=audio 9 UDP/TLS/RTP/SAVPF 8
    a=mid:3
    a=rtpmap:8 PCMA/8000
    a=fmtp:8 maxptime=40
    a=recvonly
    """)

    private static func fmtps(_ sdp: String) -> [String] {
        SDP(parsing: sdp).mediaSections.flatMap(\.fmtps).map { "a=fmtp:\($0.payload) \($0.config)" }
    }

    @Test(.spec("https://datatracker.ietf.org/doc/html/rfc7587#section-7.1"))
    func addsStereoOnlyToSectionsTheOfferSendsInStereo() {
        let munged = Transport.mungeOpusStereo(Self.answer, matchingOffer: Self.offer)

        #expect(Self.fmtps(munged) == [
            "a=fmtp:111 minptime=10;useinbandfec=1;stereo=1", // mid 0: offered stereo
            "a=fmtp:111 minptime=10;useinbandfec=1", // mid 1: Opus, but mono
            "a=fmtp:8 maxptime=40", // mid 3: not Opus
        ])
    }

    /// `sprop-stereo=1` contains "stereo=1" as a substring, so a `contains` check —
    /// as in client-sdk-js — reads the section as already stereo and skips it,
    /// leaving the receiver in mono. That is the exact case this code exists to fix,
    /// so it is pinned here as well as in ``SDPTests``.
    @Test func spropStereoDoesNotSuppressTheReceiverPreference() {
        // Answering with the offer's own SDP is the worst case: every stereo section
        // already carries the substring.
        let munged = Transport.mungeOpusStereo(Self.offer, matchingOffer: Self.offer)

        #expect(Self.fmtps(munged).first == "a=fmtp:111 minptime=10;useinbandfec=1;sprop-stereo=1;stereo=1")
    }

    @Test func isIdempotent() {
        let once = Transport.mungeOpusStereo(Self.answer, matchingOffer: Self.offer)
        #expect(Transport.mungeOpusStereo(once, matchingOffer: Self.offer) == once)
    }

    /// No stereo anywhere in the offer must return the answer untouched rather than
    /// round-tripped, so the caller's `munged != answer` check stays false and no
    /// munged description is ever offered to libwebrtc.
    @Test func offerWithoutStereoReturnsTheAnswerUnchanged() {
        let monoOffer = Self.offer.replacingOccurrences(of: ";sprop-stereo=1", with: "")
            .replacingOccurrences(of: "a=fmtp:8 sprop-stereo=1", with: "a=fmtp:8 maxptime=40")
            .replacingOccurrences(of: "a=fmtp:111 sprop-stereo=1", with: "a=fmtp:111 useinbandfec=1")

        #expect(Transport.mungeOpusStereo(Self.answer, matchingOffer: monoOffer) == Self.answer)
    }

    /// Sections are keyed by mid, not by position — an answer that lists them in a
    /// different order still gets the parameter on the right one.
    @Test func matchesByMidRatherThanSectionOrder() {
        let reordered = Self.sdp("""
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:1
        a=rtpmap:111 opus/48000/2
        a=fmtp:111 useinbandfec=1
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=rtpmap:111 opus/48000/2
        a=fmtp:111 useinbandfec=1
        """)
        let munged = Transport.mungeOpusStereo(reordered, matchingOffer: Self.offer)

        #expect(Self.fmtps(munged) == [
            "a=fmtp:111 useinbandfec=1", // mid 1
            "a=fmtp:111 useinbandfec=1;stereo=1", // mid 0
        ])
    }

    /// The Opus payload type is read from each document's own `a=rtpmap` rather than
    /// carried over from the offer.
    @Test func resolvesThePayloadTypeWithinTheAnswer() {
        let renumbered = Self.sdp("""
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 63
        a=mid:0
        a=rtpmap:63 opus/48000/2
        a=fmtp:63 useinbandfec=1
        """)

        #expect(Transport.mungeOpusStereo(renumbered, matchingOffer: Self.offer)
            .contains("a=fmtp:63 useinbandfec=1;stereo=1"))
    }

    /// ``SDPMediaSection/appendFmtpParameter(_:forPayload:)`` never inserts an fmtp
    /// line, so an answer that omits one for Opus is left alone. libwebrtc always
    /// emits `minptime`/`useinbandfec`, so this is a documented boundary rather than
    /// a path taken in practice.
    @Test func leavesAnAnswerWithoutAnOpusFmtpLineUntouched() {
        let noFmtp = Self.sdp("""
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=rtpmap:111 opus/48000/2
        """)

        #expect(Transport.mungeOpusStereo(noFmtp, matchingOffer: Self.offer) == noFmtp)
    }

    /// A section the offer never mentioned, and one whose mid matches but which
    /// carries no Opus: both are skipped without disturbing the document.
    @Test func skipsUnmatchedAndNonOpusAnswerSections() {
        let extra = Self.sdp("""
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:99
        a=rtpmap:111 opus/48000/2
        a=fmtp:111 useinbandfec=1
        m=audio 9 UDP/TLS/RTP/SAVPF 8
        a=mid:0
        a=rtpmap:8 PCMA/8000
        a=fmtp:8 maxptime=40
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=rtpmap:111 opus/48000/2
        a=fmtp:111 useinbandfec=1
        """)

        #expect(Transport.mungeOpusStereo(extra, matchingOffer: Self.offer) == extra)
    }
}
