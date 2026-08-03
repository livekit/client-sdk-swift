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
}
