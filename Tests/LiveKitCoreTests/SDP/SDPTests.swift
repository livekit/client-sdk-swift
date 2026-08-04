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
struct SDPTests {
    /// LF/CRLF/lone-CR, with and without a trailing newline.
    private static func eolVariants(of fixture: String) -> [String] {
        let crlf = fixture.replacingOccurrences(of: "\n", with: "\r\n")
        let cr = fixture.replacingOccurrences(of: "\n", with: "\r")
        return [fixture, fixture + "\n", crlf, crlf + "\r\n", cr, cr + "\r"]
    }

    // MARK: - Round-trip

    @Test(arguments: SDPFixture.byName.keys.sorted())
    func roundTripIsIdentity(fixtureName: String) throws {
        let fixture = try #require(SDPFixture.byName[fixtureName])
        for sdp in Self.eolVariants(of: fixture) {
            #expect(SDP(parsing: sdp).write() == sdp)
        }
    }

    @Test(arguments: ["", "\n", "\r\n", "v=0", "v=0\r\ns=-\r\n"])
    func roundTripOfDegenerateInputs(sdp: String) {
        #expect(SDP(parsing: sdp).write() == sdp)
    }

    // MARK: - Parsing

    @Test func splitsSessionAndMediaSections() {
        let document = SDP(parsing: SDPFixture.jsep)

        #expect(document.sessionLines.first == "v=0")
        #expect(document.sessionLines.count == 6)
        #expect(document.mediaSections.map(\.mediaType) == ["audio", "video"])
        #expect(document.mediaSections.map(\.mid) == ["a1", "v1"])
        #expect(document.mediaSections.allSatisfy { $0.direction == .sendrecv })
    }

    @Test func detectsRTPSections() {
        #expect(SDP(parsing: SDPFixture.normal).mediaSections.map(\.isRTP) == [true, true])
        #expect(SDP(parsing: SDPFixture.simulcast).mediaSections.map(\.isRTP) == [true, true])

        let dataChannel = SDP(parsing: SDPFixture.dataChannel)
        #expect(dataChannel.mediaSections.map(\.isRTP) == [true, false])
        #expect(dataChannel.mediaSections.map(\.mediaType) == ["audio", "application"])
    }

    @Test func parsesRtpmaps() throws {
        let document = SDP(parsing: SDPFixture.normal)
        let audio = try #require(document.mediaSections.first)

        #expect(audio.rtpmaps == [
            SDPRtpmap(payload: "0", encoding: "PCMU/8000"),
            SDPRtpmap(payload: "96", encoding: "opus/48000"),
        ])
        #expect(audio.rtpmaps.last?.codec == "opus")
        #expect(audio.mid == nil)
    }

    @Test func parsesFmtps() throws {
        let document = SDP(parsing: SDPFixture.normal)
        let video = try #require(document.mediaSections.last)

        #expect(video.fmtps.count == 2)
        #expect(video.fmtps.first?.payload == "97")

        let fmtp = video.fmtp(forPayload: "98")
        #expect(fmtp?.config == "minptime=10; useinbandfec=1")
        // Space-padded configs are normalized at the parameter level.
        #expect(fmtp?.parameters == ["minptime=10", "useinbandfec=1"])
    }

    @Test func findsFmtpListedBeforeItsRtpmap() throws {
        // In `normal`, `a=fmtp:98` appears before `a=rtpmap:98`.
        let document = SDP(parsing: SDPFixture.normal)
        let video = try #require(document.mediaSections.last)

        #expect(video.payload(forCodec: "VP8") == "98")
        #expect(video.fmtp(forPayload: "98") != nil)
    }

    @Test func findsPayloadForCodecCaseInsensitively() throws {
        // RTP payload format names are case-insensitive media subtypes (RFC 4855 §4).
        // client-sdk-js is inconsistent here (case-insensitive for video codecs,
        // case-sensitive for opus); we are uniformly case-insensitive.
        let video = try #require(SDP(parsing: SDPFixture.normal).mediaSections.last)
        #expect(video.payload(forCodec: "h264") == "97")
        #expect(video.payload(forCodec: "av1") == nil)

        let audio = try #require(SDP(parsing: SDPFixture.jsep).mediaSections.first)
        #expect(audio.payload(forCodec: "OPUS") == "96")
    }

    @Test func firstPayloadWinsWhenCodecHasMultiplePayloads() throws {
        // `simulcast` maps H264 to payloads 97, 98 and 99 — the first rtpmap wins,
        // matching client-sdk-js (`Array.find` in applyVideoStartBitrate).
        let video = try #require(SDP(parsing: SDPFixture.simulcast).mediaSections.last)
        #expect(video.payload(forCodec: "H264") == "97")
    }

    @Test func readsAttributeValues() throws {
        let audio = try #require(SDP(parsing: SDPFixture.jsep).mediaSections.first)
        #expect(audio.attributeValue("ice-ufrag") == "ETEn1v9DoTMB9J4r")
        #expect(audio.attributeValue("nonexistent") == nil)
    }

    @Test func parsesLoneCarriageReturnEOL() throws {
        let document = SDP(parsing: SDPFixture.dataChannel.replacingOccurrences(of: "\n", with: "\r"))

        #expect(document.mediaSections.map(\.mid) == ["0", "1"])
        let audio = try #require(document.mediaSections.first)
        #expect(audio.direction == .inactive)
        #expect(audio.payload(forCodec: "opus") == "111")
    }

    @Test func typedAccessorsIgnoreUnknownLines() throws {
        let document = SDP(parsing: SDPFixture.unknownLines)

        #expect(document.sessionLines.contains("y=session-level-unknown-line-type"))
        let audio = try #require(document.mediaSections.first)
        #expect(audio.mid == "0")
        #expect(audio.direction == .sendonly)
        #expect(audio.payload(forCodec: "opus") == "111")
    }

    @Test func skipsMalformedAttributeLines() throws {
        let lines = [
            "m=audio 9 UDP/TLS/RTP/SAVPF 111", // no session prelude
            "a=rtpmap:111", // no value
            "a=rtpmap: opus/48000/2", // empty payload
            "a=fmtp:111 ", // empty config
            "a=rtpmap:111 opus/48000/2", // valid
        ]
        let sdp = lines.joined(separator: "\r\n")
        let document = SDP(parsing: sdp)

        #expect(document.write() == sdp)
        #expect(document.sessionLines.isEmpty)
        let audio = try #require(document.mediaSections.first)
        #expect(audio.rtpmaps == [SDPRtpmap(payload: "111", encoding: "opus/48000/2")])
        #expect(audio.fmtps.isEmpty)
    }

    @Test func rtpmapCodecFallsBackToRawEncoding() {
        #expect(SDPRtpmap(payload: "96", encoding: "/").codec == "/")
    }

    @Test func emptyMediaSectionBehavesGracefully() {
        let section = SDPMediaSection(lines: [])
        #expect(section.mediaType == "")
        #expect(!section.isRTP)
        #expect(section.direction == nil)
    }

    // MARK: - Mutation

    @Test func setDirectionReplacesInPlace() throws {
        var document = SDP(parsing: SDPFixture.dataChannel)
        try #require(document.mediaSections.count == 2)
        let inactiveIndex = document.mediaSections[0].lines.firstIndex(of: "a=inactive")

        document.mediaSections[0].set(direction: .recvonly)

        #expect(document.mediaSections[0].lines.firstIndex(of: "a=recvonly") == inactiveIndex)
        let expected = SDPFixture.dataChannel.replacingOccurrences(of: "a=inactive", with: "a=recvonly")
        #expect(document.write() == expected)
    }

    @Test func setDirectionAppendsWhenAbsent() throws {
        var document = SDP(parsing: SDPFixture.simulcast)
        try #require(document.mediaSections.count == 2)
        #expect(document.mediaSections[0].direction == nil)

        document.mediaSections[0].set(direction: .recvonly)

        #expect(document.mediaSections[0].lines.last == "a=recvonly")
        #expect(document.mediaSections[0].direction == .recvonly)
    }

    @Test func appendsFmtpParameter() throws {
        var document = SDP(parsing: SDPFixture.jsep)
        try #require(document.mediaSections.count == 2)

        let changed = document.mediaSections[1].appendFmtpParameter("x-google-start-bitrate=1000", forPayload: "101")

        #expect(changed)
        #expect(document.mediaSections[1].fmtp(forPayload: "101")?.config == "apt=100;x-google-start-bitrate=1000")

        // Exact parameter already present — no double append.
        let changedAgain = document.mediaSections[1].appendFmtpParameter("x-google-start-bitrate=1000", forPayload: "101")
        #expect(!changedAgain)
        #expect(document.mediaSections[1].fmtp(forPayload: "101")?.config == "apt=100;x-google-start-bitrate=1000")
    }

    @Test(.spec("https://datatracker.ietf.org/doc/html/rfc7587#section-7.1"))
    func appendFmtpParameterMatchesExactParameterOnly() throws {
        // "sprop-stereo=1" must not satisfy a check for "stereo=1" — RFC 7587 defines
        // them as distinct parameters (sender capability vs receiver preference).
        // Deliberate non-parity: client-sdk-js uses a substring check and skips the
        // append when only sprop-stereo=1 is present.
        var document = SDP(parsing: SDPFixture.dataChannel)
        try #require(document.mediaSections.count == 2)
        document.mediaSections[0].appendFmtpParameter("sprop-stereo=1", forPayload: "111")

        let changed = document.mediaSections[0].appendFmtpParameter("stereo=1", forPayload: "111")

        #expect(changed)
        #expect(document.mediaSections[0].fmtp(forPayload: "111")?.config
            == "minptime=10;useinbandfec=1;sprop-stereo=1;stereo=1")
    }

    @Test func appendFmtpParameterHandlesSpacePaddedConfigs() throws {
        var document = SDP(parsing: SDPFixture.normal)
        try #require(document.mediaSections.count == 2)
        // Already present as "minptime=10; useinbandfec=1" — must be recognized despite padding.
        let changed = document.mediaSections[1].appendFmtpParameter("useinbandfec=1", forPayload: "98")
        #expect(!changed)
    }

    @Test func appendFmtpParameterWithoutFmtpLineIsNoOp() throws {
        var document = SDP(parsing: SDPFixture.normal)
        try #require(!document.mediaSections.isEmpty)
        let changed = document.mediaSections[0].appendFmtpParameter("stereo=1", forPayload: "0")
        #expect(!changed)
        #expect(document.write() == SDPFixture.normal)
    }

    @Test func appendsLineAtEndOfSection() throws {
        var document = SDP(parsing: SDPFixture.jsep)
        try #require(!document.mediaSections.isEmpty)

        document.mediaSections[0].append(line: "a=rtcp-fb:96 nack")

        let lines = document.write().components(separatedBy: "\n")
        let appendedIndex = lines.firstIndex(of: "a=rtcp-fb:96 nack")
        let videoMLineIndex = lines.firstIndex { $0.hasPrefix("m=video") }
        #expect(appendedIndex != nil)
        #expect(appendedIndex.map { $0 + 1 } == videoMLineIndex)
    }
}
