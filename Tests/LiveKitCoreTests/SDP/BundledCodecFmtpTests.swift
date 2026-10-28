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
struct BundledCodecFmtpTests {
    /// The single PC publisher shape: a sending Opus section and a sending video section
    /// carrying the start-bitrate hint, each paired with a receive section preallocated for
    /// subscribed media that shares its payload types — payload 100 (VP8) without an fmtp line
    /// at all, which is how libwebrtc offers it.
    private static let singlePCOffer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0 1 2 3
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:0
    a=msid:- mic
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 minptime=10;useinbandfec=1;stereo=1
    a=sendonly
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:1
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 minptime=10;useinbandfec=1
    a=recvonly
    m=video 9 UDP/TLS/RTP/SAVPF 96 100
    a=mid:2
    a=msid:- cam
    a=rtpmap:96 H264/90000
    a=fmtp:96 packetization-mode=1;x-google-start-bitrate=900
    a=rtpmap:100 VP8/90000
    a=fmtp:100 x-google-start-bitrate=900
    a=sendonly
    m=video 9 UDP/TLS/RTP/SAVPF 96 100
    a=mid:3
    a=rtpmap:96 H264/90000
    a=fmtp:96 packetization-mode=1
    a=rtpmap:100 VP8/90000
    a=recvonly
    """.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"

    /// Both ways a receive section can diverge are repaired: payload 96 has an fmtp line
    /// missing the parameter, payload 100 has no fmtp line at all.
    @Test func conformsReceiveSectionsToTheSendingConfig() {
        let sections = SDP(parsing: Transport.conformBundledCodecFmtp(Self.singlePCOffer)).mediaSections

        #expect(sections[1].fmtps.map(\.config) == ["minptime=10;useinbandfec=1;stereo=1"])
        #expect(sections[3].fmtps.map(\.config) == ["packetization-mode=1;x-google-start-bitrate=900",
                                                    "x-google-start-bitrate=900"])
        // Inserted rather than rewritten, so it lands at the end of its own section.
        #expect(sections[3].lines.last == "a=fmtp:100 x-google-start-bitrate=900")
    }

    @Test func leavesSendingSectionsUntouched() {
        let conformed = SDP(parsing: Transport.conformBundledCodecFmtp(Self.singlePCOffer)).mediaSections
        let original = SDP(parsing: Self.singlePCOffer).mediaSections

        #expect(conformed[0].lines == original[0].lines)
        #expect(conformed[2].lines == original[2].lines)
    }

    /// A sending section is authoritative wherever it appears, so an offer that lists the
    /// receive sections first conforms the same way.
    @Test func sendingSectionWinsRegardlessOfOrder() {
        let reordered = SDP(parsing: Self.singlePCOffer)
        var swapped = reordered
        swapped.mediaSections = [reordered.mediaSections[1], reordered.mediaSections[0],
                                 reordered.mediaSections[3], reordered.mediaSections[2]]

        let sections = SDP(parsing: Transport.conformBundledCodecFmtp(swapped.write())).mediaSections

        #expect(sections[0].fmtps.map(\.config) == ["minptime=10;useinbandfec=1;stereo=1"])
        #expect(sections[2].fmtps.map(\.config) == ["packetization-mode=1;x-google-start-bitrate=900",
                                                    "x-google-start-bitrate=900"])
    }

    /// With no sending section to copy from, the receive sections still converge on one
    /// config — two of them disagreeing is a bundle collision just the same.
    @Test func receiveSectionsConvergeWithoutASendingSection() {
        let receiveOnly = Self.singlePCOffer
            .replacingOccurrences(of: "a=fmtp:96 packetization-mode=1;x-google-start-bitrate=900\r\n", with: "")
            .replacingOccurrences(of: "a=fmtp:100 x-google-start-bitrate=900\r\n", with: "")
            .replacingOccurrences(of: "a=sendonly", with: "a=recvonly")

        let sections = SDP(parsing: Transport.conformBundledCodecFmtp(receiveOnly)).mediaSections

        #expect(Set(sections[0].fmtps.map(\.config)) == Set(sections[1].fmtps.map(\.config)))
        #expect(sections[2].fmtps.map(\.config) == sections[3].fmtps.map(\.config))
    }

    /// `inactive` is the other direction a section with no outgoing track lands on — an
    /// unpublished track leaves one behind — so it is conformed too.
    @Test func treatsInactiveAsReceiveOnly() {
        let inactive = Self.singlePCOffer.replacingOccurrences(of: "a=mid:3\r\n", with: "a=mid:3\r\na=inactive\r\n")
        let sections = SDP(parsing: Transport.conformBundledCodecFmtp(inactive)).mediaSections

        #expect(sections[3].fmtps.map(\.config) == ["packetization-mode=1;x-google-start-bitrate=900",
                                                    "x-google-start-bitrate=900"])
    }

    /// A section with no direction attribute defaults to `sendrecv` (RFC 8866 §6.7), so it is
    /// a sending section and must not be rewritten.
    @Test func sectionWithoutDirectionCountsAsSending() {
        let noDirection = Self.singlePCOffer.replacingOccurrences(
            of: "a=rtpmap:100 VP8/90000\r\na=recvonly", with: "a=rtpmap:100 VP8/90000",
        )
        let sections = SDP(parsing: Transport.conformBundledCodecFmtp(noDirection)).mediaSections
        let original = SDP(parsing: noDirection).mediaSections

        #expect(sections[3].lines == original[3].lines)
    }

    @Test func isIdempotentAndPreservesUnrelatedSDP() {
        let once = Transport.conformBundledCodecFmtp(Self.singlePCOffer)

        #expect(Transport.conformBundledCodecFmtp(once) == once)
        #expect(once.hasSuffix("\r\n"))
        // Nothing to conform: no receive section, so byte-identical.
        #expect(Transport.conformBundledCodecFmtp(once.replacingOccurrences(of: "a=recvonly", with: "a=sendrecv"))
            == once.replacingOccurrences(of: "a=recvonly", with: "a=sendrecv"))
    }

    /// A payload a sending section declares with no fmtp at all is canonical in that state, so a
    /// receive section carrying parameters for it is stripped rather than left to collide. The
    /// rewrite only visits receive sections, so recording the absence is the only way this
    /// resolves.
    @Test func sendingSectionWithoutFmtpStripsTheReceiveSection() {
        let senderBare = Self.singlePCOffer
            .replacingOccurrences(of: "a=fmtp:100 x-google-start-bitrate=900\r\n", with: "")
        let sections = SDP(parsing: Transport.conformBundledCodecFmtp(senderBare)).mediaSections

        // Sending section (mid 2) declares 100 with no fmtp; the receive section must match.
        #expect(sections[2].fmtp(forPayload: "100") == nil)
        #expect(sections[3].fmtp(forPayload: "100") == nil)
        #expect(Self.fmtpConfigsByPayload(Transport.conformBundledCodecFmtp(senderBare))
            .allSatisfy { $0.value.count == 1 })
    }

    /// The pipeline the publisher actually runs: the start-bitrate munge diverges the shared
    /// payload types, the conform pass puts them back. Expressed as the invariant libwebrtc
    /// enforces — one fmtp config per payload type across the BUNDLE group — rather than as
    /// specific strings.
    @Test func startBitrateFollowedByConformLeavesNoCollision() {
        let unconformed = Transport.mungeVideoStartBitrate(Self.singlePCOffer, kbpsBySenderId: ["cam": 1000])
        let conformed = Transport.conformBundledCodecFmtp(unconformed)

        #expect(Self.fmtpConfigsByPayload(unconformed).contains { $0.value.count > 1 })
        #expect(Self.fmtpConfigsByPayload(conformed).allSatisfy { $0.value.count == 1 })
    }

    /// Every fmtp config each payload type is given across the document, keyed by payload. A
    /// payload declared by `a=rtpmap` but given no fmtp line contributes the empty config,
    /// since "parameters" and "no parameters" collide just as two different parameter sets do.
    private static func fmtpConfigsByPayload(_ sdp: String) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for section in SDP(parsing: sdp).mediaSections {
            for rtpmap in section.rtpmaps {
                result[rtpmap.payload, default: []].insert(section.fmtp(forPayload: rtpmap.payload)?.config ?? "")
            }
        }
        return result
    }
}
