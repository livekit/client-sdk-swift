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

/// `normal`, `jsep` and `simulcast` are ported from the sdp-transform test suite
/// (MIT): https://github.com/clux/sdp-transform/tree/master/test
enum SDPFixture {
    static let normal = """
    v=0
    o=- 20518 0 IN IP4 203.0.113.1
    s=
    t=0 0
    c=IN IP4 203.0.113.1
    a=ice-ufrag:F7gI
    a=ice-pwd:x9cml/YzichV2+XlhiMu8g
    a=fingerprint:sha-1 42:89:c5:c6:55:9d:6e:c8:e8:83:55:2a:39:f9:b6:eb:e9:a3:a9:e7
    a=setup:actpass
    m=audio 54400 RTP/SAVPF 0 96
    a=rtpmap:0 PCMU/8000
    a=rtpmap:96 opus/48000
    a=extmap:1 URI-toffset
    a=extmap:2/recvonly URI-gps-string
    a=extmap-allow-mixed
    a=ptime:20
    a=sendrecv
    a=candidate:0 1 UDP 2113667327 203.0.113.1 54400 typ host
    a=candidate:1 2 UDP 2113667326 203.0.113.1 54401 typ host
    m=video 55400 RTP/SAVPF 97 98
    a=rtpmap:97 H264/90000
    a=fmtp:97 profile-level-id=4d0028;packetization-mode=1;sprop-parameter-sets=Z0IAH5WoFAFuQA==,aM48gA==
    a=fmtp:98 minptime=10; useinbandfec=1
    a=rtpmap:98 VP8/90000
    a=rtcp-fb:* nack
    a=rtcp-fb:98 nack rpsi
    a=rtcp-fb:98 trr-int 100
    a=crypto:1 AES_CM_128_HMAC_SHA1_32 inline:keNcG3HezSNID7LmfDa9J4lfdUL8W1F7TNJKcbuy|2^20|1:32
    a=sendrecv
    a=ssrc:1399694169 foo:bar
    a=ssrc:1399694169 baz
    """

    static let jsep = """
    v=0
    o=- 4962303333179871722 1 IN IP4 0.0.0.0
    s=-
    t=0 0
    a=msid-semantic:WMS
    a=group:BUNDLE a1 v1
    m=audio 56500 UDP/TLS/RTP/SAVPF 96 0 8 97 98
    c=IN IP4 192.0.2.1
    a=mid:a1
    a=rtcp:56501 IN IP4 192.0.2.1
    a=msid:- f83006c5-a0ff-4e0a-9ed9-d3e6747be7d9
    a=sendrecv
    a=rtpmap:96 opus/48000/2
    a=rtpmap:0 PCMU/8000
    a=rtpmap:8 PCMA/8000
    a=rtpmap:97 telephone-event/8000
    a=rtpmap:98 telephone-event/48000
    a=maxptime:120
    a=ice-ufrag:ETEn1v9DoTMB9J4r
    a=ice-pwd:OtSK0WpNtpUjkY4+86js7ZQl
    a=ice-options:trickle
    a=setup:actpass
    a=rtcp-mux
    a=rtcp-rsize
    a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
    a=candidate:3348148302 1 udp 2113937151 192.0.2.1 56500 typ host
    a=end-of-candidates
    m=video 0 UDP/TLS/RTP/SAVPF 100 101
    c=IN IP4 192.0.2.1
    a=rtcp:56503 IN IP4 192.0.2.1
    a=mid:v1
    a=bundle-only
    a=sendrecv
    a=rtpmap:100 VP8/90000
    a=rtpmap:101 rtx/90000
    a=fmtp:101 apt=100
    a=rtcp-fb:100 ccm fir
    a=rtcp-fb:100 nack
    a=rtcp-fb:100 nack pli
    a=ssrc:1366781083 cname:EocUG1f0fcg/yvY7
    a=ssrc-group:FID 1366781083 1366781084
    a=end-of-candidates
    """

    static let simulcast = """
    v=0
    o=alice 2362969037 2362969040 IN IP4 192.0.2.156
    s=Simulcast Enabled Client
    t=0 0
    c=IN IP4 192.0.2.156
    m=audio 49200 RTP/AVP 0
    a=rtpmap:0 PCMU/8000
    m=video 49300 RTP/AVP 97 98 99 100
    a=rtpmap:97 H264/90000
    a=rtpmap:98 H264/90000
    a=rtpmap:99 H264/90000
    a=rtpmap:100 VP8/90000
    a=fmtp:97 profile-level-id=42c01f; max-fs=3600; max-mbps=108000
    a=fmtp:98 profile-level-id=42c00b; max-fs=240; max-mbps=3600
    a=fmtp:99 profile-level-id=42c00b; max-fs=120; max-mbps=1800
    a=extmap:1 urn:ietf:params:rtp-hdrext:sdes:RtpStreamId
    a=imageattr:97 send [x=1280,y=720] recv [x=1280,y=720] [x=320,y=180] [x=160,y=90]
    a=imageattr:98 send [x=320,y=180]
    a=imageattr:99 send [x=160,y=90]
    a=imageattr:100 recv [x=1280,y=720] [x=320,y=180] send [x=1280,y=720]
    a=imageattr:* recv *
    a=rid:1 send pt=97;max-width=1280;max-height=720;max-fps=30
    a=rid:2 send pt=98
    a=rid:3 send pt=99
    a=rid:4 send pt=100
    a=rid:c recv pt=97
    a=simulcast:send 1,~4;2;3 recv c
    a=simulcast: send rid=1,4;2;3 paused=4 recv rid=c
    """

    /// libwebrtc-style offer with an audio section and a data channel section.
    static let dataChannel = """
    v=0
    o=- 3828566255 3 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0 1
    a=msid-semantic: WMS
    m=audio 9 UDP/TLS/RTP/SAVPF 111 63
    c=IN IP4 0.0.0.0
    a=rtcp:9 IN IP4 0.0.0.0
    a=ice-ufrag:someufrag
    a=mid:0
    a=inactive
    a=rtpmap:111 opus/48000/2
    a=fmtp:111 minptime=10;useinbandfec=1
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    c=IN IP4 0.0.0.0
    a=mid:1
    a=sctp-port:5000
    a=max-message-size:262144
    """

    /// Unknown line types and attributes that must survive munging untouched.
    /// sdp-transform silently drops unknown line types (e.g. `y=`) and relocates
    /// unknown `a=` lines after recognized ones — `SDP` deliberately does neither.
    static let unknownLines = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    y=session-level-unknown-line-type
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    b=AS:64
    a=mid:0
    a=x-custom-flag
    a=x-google-flag:conference
    a=rtpmap:111 opus/48000/2
    a=sendonly
    a=ssrc:42 cname:test
    """

    static let byName: [String: String] = [
        "normal": normal,
        "jsep": jsep,
        "simulcast": simulcast,
        "dataChannel": dataChannel,
        "unknownLines": unknownLines,
    ]
}
