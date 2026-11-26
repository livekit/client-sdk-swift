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

/// `removeFlexFEC()` keeps simulcast senders from negotiating FlexFEC, which would abort the
/// process in libwebrtc's send statistics. Runs without a server or the FlexFEC field trials:
/// without them only receiving supports `flexfec-03`, so a receive-only section offering it stands
/// in for a sender with FlexFEC enabled. The filtering does not depend on the direction.
@Suite(.tags(.media))
struct RemoveFlexFECTests {
    /// Carries the transceiver between executor hops; it is only touched on the RTC executor.
    private final class TransceiverBox: @unchecked Sendable {
        let transceiver: LKRTCRtpTransceiver
        init(_ transceiver: LKRTCRtpTransceiver) { self.transceiver = transceiver }
    }

    private func videoCodecs(_ sdp: String) -> [String] {
        SDP(parsing: sdp).mediaSections
            .filter { $0.mediaType == "video" }
            .flatMap { $0.rtpmaps.map { $0.codec.lowercased() } }
    }

    @Test func removesFlexFECFromOffer() async throws {
        try await withLiveTransport { transport in
            let box = try await RTC.run {
                let transceiverInit = LKRTCRtpTransceiverInit()
                transceiverInit.direction = .recvOnly
                let transceiver = try transport.addTransceiver(ofType: .video, transceiverInit: transceiverInit)
                let codecs = RTC.peerConnectionFactory.rtpReceiverCapabilities(forKind: kLKRTCMediaStreamTrackKindVideo).codecs
                try transceiver.setCodecPreferences(codecs, error: ())
                return TransceiverBox(transceiver)
            }

            let before = try await transport.createOffer()
            try #require(videoCodecs(before.sdp).contains("flexfec-03"), "precondition: the offer carries FlexFEC")

            let order = try await RTC.run {
                let order = box.transceiver.codecPreferences.map { $0.name.lowercased() }
                try box.transceiver.removeFlexFEC()
                return order
            }

            let after = try await transport.createOffer()
            #expect(!videoCodecs(after.sdp).contains("flexfec-03"))

            // the other preferences keep their order
            let remaining = await RTC.run { box.transceiver.codecPreferences.map { $0.name.lowercased() } }
            #expect(remaining == order.filter { $0 != "flexfec-03" })
        }
    }

    /// Without codec preferences, the sender capabilities are filtered instead. They carry
    /// FlexFEC only when the field trials are on, so either outcome is checked.
    @Test func filtersSenderCapabilitiesWithoutPreferences() async throws {
        try await withLiveTransport { transport in
            let (preferences, capabilities) = try await RTC.run {
                let transceiver = try transport.addTransceiver(ofType: .video, transceiverInit: LKRTCRtpTransceiverInit())
                try transceiver.removeFlexFEC()
                return (transceiver.codecPreferences.map { $0.name.lowercased() },
                        RTC.videoSenderCapabilities.codecs.map { $0.name.lowercased() })
            }

            if capabilities.contains("flexfec-03") {
                #expect(preferences == capabilities.filter { $0 != "flexfec-03" })
            } else {
                #expect(preferences.isEmpty, "Expected no preferences when there is no FlexFEC to remove")
            }
        }
    }
}
