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
struct OpusNackOfferTests {
    @Test(arguments: ["sendonly", "recvonly", "sendrecv", "inactive"], ["\n", "\r\n", "\r"])
    func addsPlainNackToEveryOpusPayload(direction: String, eol: String) {
        let offer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 109 112",
            "a=\(direction)",
            "a=rtpmap:109 OPUS/48000/2",
            "a=rtpmap:112 opus/48000/2",
            "a=rtcp-fb:109 nack pli",
            "m=video 9 UDP/TLS/RTP/SAVPF 109",
            "a=rtpmap:109 VP8/90000",
            "m=audio 9 UDP/TLS/RTP/SAVPF 109",
            "a=rtpmap:109 PCMU/8000",
            "",
        ].joined(separator: eol)
        let expected = offer.replacingOccurrences(
            of: "m=video ",
            with: "a=rtcp-fb:109 nack\(eol)a=rtcp-fb:112 nack\(eol)m=video ",
        )
        let munged = Transport.mungeOpusNackForAllAudio(offer)
        #expect(munged == expected)
        #expect(Transport.mungeOpusNackForAllAudio(munged) == munged)
    }

    @Test(arguments: ["109", "*"])
    func preservesExistingPlainAndWildcardNack(payload: String) {
        let offer = "m=audio 9 UDP/TLS/RTP/SAVPF 109\r\na=rtpmap:109 opus/48000/2\r\na=rtcp-fb:\(payload) nack\r\n"
        #expect(Transport.mungeOpusNackForAllAudio(offer) == offer)
    }

    @Test(arguments: ["", "v=0\n", "m=audio 9 UDP/TLS/RTP/SAVPF 0\na=rtpmap:0 PCMU/8000"])
    func leavesDocumentsWithoutOpusAudioUnchanged(offer: String) {
        #expect(Transport.mungeOpusNackForAllAudio(offer) == offer)
    }

    @Test(arguments: [true, false])
    func ordinaryOffersEnableNackOnlyInSinglePCMode(singlePCMode: Bool) async throws {
        try await withLiveTransport(singlePCMode: singlePCMode) { transport in
            try await addAudioSections(to: transport)
            let offers = Offers()
            await transport.set { offer, _ in await offers.append(offer) }

            try await transport.createAndSendOffer()

            let offer = try #require(await offers.last)
            try expectNack(in: offer.sdp, audioSections: 3, enabled: singlePCMode)
        }
    }

    @Test func initialOfferCarriesNackAndRemainsDeferredUntilTheAnswer() async throws {
        try await withLiveTransport(singlePCMode: true) { transport in
            try await addAudioSections(to: transport)
            let initial = try #require(await transport.createInitialOffer())
            try expectNack(in: initial.offer.sdp, audioSections: 3, enabled: true)
            #expect(await transport.localDescription == nil)
            #expect(await transport.signalingState == .stable)

            try await answerWithoutMedia(transport, offer: initial.offer, offerId: initial.offerId)
            let applied = try #require(await transport.localDescription)
            try expectNack(in: applied.sdp, audioSections: 3, enabled: true)
            #expect(await transport.signalingState == .stable)
        }
    }

    @Test func sendOnlyOfferAdvertisesNackBeforeAnySubscription() async throws {
        try await withLiveTransport(singlePCMode: true) { transport in
            try await RTC.run {
                let send = LKRTCRtpTransceiverInit()
                send.direction = .sendOnly
                _ = try transport.addTransceiver(ofType: .audio, transceiverInit: send)
            }
            let offers = Offers()
            await transport.set { offer, _ in await offers.append(offer) }
            try await transport.createAndSendOffer()
            let first = try #require(await offers.last)
            try expectNack(in: first.sdp, audioSections: 1, enabled: true)
            #expect(SDP(parsing: first.sdp).mediaSections.first?.direction == .sendonly)

            try await answerWithoutMedia(transport, offer: first)
            try await RTC.run {
                let receive = LKRTCRtpTransceiverInit()
                receive.direction = .recvOnly
                _ = try transport.addTransceiver(ofType: .audio, transceiverInit: receive)
            }
            try await transport.createAndSendOffer()
            let second = try #require(await offers.last)
            try expectNack(in: second.sdp, audioSections: 2, enabled: true)
        }
    }

    /// No media flows in these negotiation tests, so the peer declines audio in its answer.
    /// This also avoids requiring an audio output device on a headless test runner.
    private func answerWithoutMedia(_ transport: Transport,
                                    offer: LKRTCSessionDescription,
                                    offerId: UInt32 = 0) async throws
    {
        try await withLiveTransport(target: .subscriber, primary: false) { answerer in
            try await answerer.set(remoteDescription: offer)
            var document = try await SDP(parsing: answerer.createAnswer().sdp)
            for index in document.mediaSections.indices where document.mediaSections[index].mediaType == "audio" {
                document.mediaSections[index].set(direction: .inactive)
            }
            let answer = RTC.createSessionDescription(type: .answer, sdp: document.write())
            try await answerer.set(localDescription: answer)
            try await transport.set(remoteDescription: answer, offerId: offerId)
        }
    }

    private func addAudioSections(to transport: Transport) async throws {
        try await RTC.run {
            for direction: LKRTCRtpTransceiverDirection in [.sendOnly, .recvOnly, .sendRecv] {
                let config = LKRTCRtpTransceiverInit()
                config.direction = direction
                _ = try transport.addTransceiver(ofType: .audio, transceiverInit: config)
            }
        }
    }

    private func expectNack(in sdp: String, audioSections: Int, enabled: Bool) throws {
        let sections = SDP(parsing: sdp).mediaSections.filter { $0.mediaType == "audio" }
        #expect(sections.count == audioSections)
        for section in sections {
            let opus = section.rtpmaps.filter { $0.codec.caseInsensitiveCompare("opus") == .orderedSame }
            try #require(!opus.isEmpty)
            for mapping in opus {
                #expect(section.hasRtcpFeedback("nack", forPayload: mapping.payload) == enabled)
            }
        }
    }

    private actor Offers {
        private var values: [LKRTCSessionDescription] = []
        var last: LKRTCSessionDescription? { values.last }
        func append(_ offer: LKRTCSessionDescription) { values.append(offer) }
    }
}
