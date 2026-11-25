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

import Foundation
@testable import LiveKit
import LiveKitWebRTC
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.e2e, .media), TestLimits.e2e)
struct OpusNackNegotiationTests {
    @Test(arguments: [false, true])
    func serverNegotiatesNackOnSinglePCAudio(sendOnlyFirst: Bool) async throws {
        try await TestEnvironment.withRoom(RoomTestingOptions(singlePeerConnection: true, canPublish: true, canSubscribe: true)) { room in
            let publisher = try #require(room._state.transport?.publisher)
            try #require(publisher.singlePCMode, "This test requires a server supporting single PC mode")

            // The first audio section determines the SFU's audio feedback, including when
            // a send-only section precedes the receiving section. No microphone is needed.
            try await RTC.run {
                if sendOnlyFirst {
                    let send = LKRTCRtpTransceiverInit()
                    send.direction = .sendOnly
                    _ = try publisher.addTransceiver(ofType: .audio, transceiverInit: send)
                }
                let receive = LKRTCRtpTransceiverInit()
                receive.direction = .recvOnly
                _ = try publisher.addTransceiver(ofType: .audio, transceiverInit: receive)
            }
            try await publisher.negotiate(force: true)

            let deadline = Date().addingTimeInterval(10)
            var descriptions: (String, String)?
            while Date() < deadline {
                descriptions = await RTC.run {
                    guard publisher.signalingState == .stable,
                          let offer = publisher.localDescription?.sdp,
                          let answer = publisher.remoteDescription?.sdp,
                          SDP(parsing: offer).mediaSections.contains(where: { $0.mediaType == "audio" })
                    else { return nil }
                    return (offer, answer)
                }
                if descriptions != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            let (offer, answer) = try #require(descriptions, "Audio sections did not finish negotiating")
            let offeredAudio = SDP(parsing: offer).mediaSections.filter { $0.mediaType == "audio" }
            #expect(offeredAudio.count == (sendOnlyFirst ? 2 : 1))
            #expect(offeredAudio.first?.direction == (sendOnlyFirst ? .sendonly : .recvonly))
            for sdp in [offer, answer] {
                let sections = SDP(parsing: sdp).mediaSections.filter { $0.mediaType == "audio" }
                try #require(!sections.isEmpty)
                for section in sections {
                    let payload = try #require(section.payload(forCodec: "opus"))
                    #expect(section.hasRtcpFeedback("nack", forPayload: payload))
                }
            }
        }
    }
}
