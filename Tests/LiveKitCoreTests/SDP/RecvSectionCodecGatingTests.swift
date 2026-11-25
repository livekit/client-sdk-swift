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
/// This is the single PC layout: receive sections are offered before anything is published, so
/// if their codec list constrained the send section, a device whose decoder lacks a codec could
/// not publish in that codec either — which is what a Jetson port hit with H.265 in rust-sdks.
/// The two SDKs build the same layout on the same libwebrtc, so the answer here is the answer
/// there.
@Suite(.tags(.media))
struct RecvSectionCodecGatingTests {
    /// When the sending section joins, relative to the exchange that negotiates the receive
    /// sections. Both orders occur: a publish before JOIN completes takes the first, and a
    /// publish on an established connection takes the second.
    enum SenderOrder: CaseIterable, CustomTestStringConvertible {
        /// The sending section is in the same offer as the receive sections.
        case sameOffer
        /// The receive sections are negotiated first, and a later offer adds the sender.
        case afterNegotiation

        var testDescription: String { "\(self)" }
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

    /// Three receive sections restricted to VP8, standing in for a decoder that supports nothing
    /// else — the Jetson case, where H.265 decode is unavailable.
    private func addVP8OnlyReceiveSections(_ transport: Transport, count: Int = 3) async throws {
        try await RTC.run {
            let vp8Only = RTC.videoSenderCapabilities.codecs.filter {
                $0.name.uppercased() == "VP8" || $0.name.uppercased() == "RTX"
            }
            let receive = LKRTCRtpTransceiverInit()
            receive.direction = .recvOnly
            for _ in 0 ..< count {
                let transceiver = try transport.addTransceiver(ofType: .video, transceiverInit: receive)
                try transceiver.setCodecPreferences(vp8Only, error: ())
            }
        }
    }

    /// Adds one sending section preferring H264, as `createSender` does.
    ///
    /// - Returns: `false` when this libwebrtc build has no H264 sender capability to probe with.
    ///   Reported outside the executor, since `return` inside `RTC.run` only exits the closure.
    private func addH264PreferringSender(_ transport: Transport) async throws -> Bool {
        try await RTC.run {
            let allVideo = RTC.videoSenderCapabilities.codecs
            guard let probe = allVideo.first(where: { $0.name.uppercased() == "H264" }) else { return false }

            let send = LKRTCRtpTransceiverInit()
            send.direction = .sendOnly
            let sender = try transport.addTransceiver(ofType: .video, transceiverInit: send)
            try sender.setCodecPreferences([probe] + allVideo.filter { $0.name != probe.name }, error: ())
            return true
        }
    }

    @Test(arguments: SenderOrder.allCases)
    func receiveSectionCodecsDoNotConstrainTheSendingSection(order: SenderOrder) async throws {
        try await withLiveTransport { transport in
            try await addVP8OnlyReceiveSections(transport)

            let offer: LKRTCSessionDescription
            switch order {
            case .sameOffer:
                try #require(await addH264PreferringSender(transport),
                             "this libwebrtc build has no H264 sender capability to probe with")
                offer = try await transport.createOffer()

            case .afterNegotiation:
                // The first description carries the receive sections and no H264 anywhere.
                let first = try await transport.createOffer()
                #expect(!videoSections(first.sdp).contains { $0.codecs.contains("H264") })

                // Settled, not left in `have-local-offer`: the SDK queues a renegotiation until
                // the answer lands, so an offer created before that is not one it would send.
                try await settleOfferAnswer(transport, offer: first)
                #expect(await transport.signalingState == .stable)

                try #require(await addH264PreferringSender(transport),
                             "this libwebrtc build has no H264 sender capability to probe with")
                offer = try await transport.createOffer()
            }

            let sections = videoSections(offer.sdp)
            let receiving = sections.filter { $0.direction == .recvonly }
            let sending = try #require(sections.first { $0.direction == .sendonly })

            // Asserted in both orders, so neither can pass with the receive sections missing or
            // unrestricted — which is what would make the sending check vacuous.
            #expect(receiving.count == 3)
            for section in receiving {
                #expect(section.codecs == ["VP8"], "mid \(section.mid) offered \(section.codecs.sorted())")
            }

            #expect(sending.codecs.contains("H264"),
                    "sending section offered \(sending.codecs.sorted()) — receive sections gated it")
        }
    }
}
