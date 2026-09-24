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
struct VideoStartBitrateTests {
    // MARK: - Per-track hint

    @Test(arguments: [
        (2_300_000, false, 1000), // camera, capped
        (800_000, false, 720),
        (334_000, false, 301),
        (3_125_000, true, 2813), // default 1080p15 screen share, under its cap
        (10_000_000, true, 3000), // 4K screen share, capped
    ])
    func hintsNinetyPercentOfTheTarget(targetBps: Int, isScreenShare: Bool, expectedKbps: Int) {
        #expect(Transport.startBitrateKbps(targetBps: targetBps, isScreenShare: isScreenShare) == expectedKbps)
    }

    /// A hint under libwebrtc's own 300 kbps default would start the estimator lower than no
    /// hint at all. A 330 kbps target would hint 297 kbps, so it gets none.
    @Test func givesNoHintBelowLibwebrtcsDefault() {
        #expect(Transport.startBitrateKbps(targetBps: 330_000, isScreenShare: false) == nil)
        #expect(Transport.startBitrateKbps(targetBps: 330_000, isScreenShare: true) == nil)
        #expect(Transport.startBitrateKbps(targetBps: 300_000, isScreenShare: false) == nil)
    }

    @Test func sumsTheActiveEncodings() {
        func encoding(_ bps: Int, active: Bool = true) -> LKRTCRtpEncodingParameters {
            let encoding = LKRTCRtpEncodingParameters()
            encoding.maxBitrateBps = NSNumber(value: bps)
            encoding.isActive = active
            return encoding
        }

        // 150 + 500 + 1700 kbps of simulcast layers is a 2350 kbps target, capped for camera.
        let simulcast = [encoding(150_000), encoding(500_000), encoding(1_700_000)]
        #expect(Transport.startBitrateKbps(for: simulcast, isScreenShare: false) == 1000)
        #expect(Transport.startBitrateKbps(for: simulcast, isScreenShare: true) == 2115)

        let lowestOnly = [encoding(150_000), encoding(500_000, active: false), encoding(1_700_000, active: false)]
        #expect(Transport.startBitrateKbps(for: lowestOnly, isScreenShare: false) == nil)

        #expect(Transport.startBitrateKbps(for: [LKRTCRtpEncodingParameters()], isScreenShare: false) == nil)
    }

    // MARK: - Connection value

    @Test func takesTheLargestHintAmongSendingSenders() {
        let hints = ["camera": 1000, "screen": 3600, "unpublished": 8000]

        #expect(Transport.connectionStartBitrateKbps(sendingSenderIds: ["camera", "screen"], kbpsBySenderId: hints) == 3600)
        #expect(Transport.connectionStartBitrateKbps(sendingSenderIds: ["camera"], kbpsBySenderId: hints) == 1000)
        #expect(Transport.connectionStartBitrateKbps(sendingSenderIds: ["audio"], kbpsBySenderId: hints) == nil)
        #expect(Transport.connectionStartBitrateKbps(sendingSenderIds: [String](), kbpsBySenderId: hints) == nil)
    }

    // MARK: - Applying it to a peer connection

    private final class StubTransportDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
        func transport(_: Transport, didRemoveTrackWithId _: String) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    /// Runs `body` with a real, offline publisher transport, closing it even when `body` throws.
    private func withTransport(_ body: (Transport) async throws -> Void) async throws {
        let transport = try await Transport(config: .liveKitDefault(),
                                            target: .publisher,
                                            primary: true,
                                            delegate: StubTransportDelegate())
        do {
            try await body(transport)
        } catch {
            await transport.close()
            throw error
        }
        await transport.close()
    }

    private func addVideoSender(to transport: Transport, startBitrateKbps: Int?) async throws -> RTCSender {
        try await RTC.run {
            let track = RTC.createVideoTrack(source: RTC.createVideoSource(forScreenShare: false))
            let transceiverInit = LKRTCRtpTransceiverInit()
            transceiverInit.direction = .sendOnly
            let transceiver = try transport.addTransceiver(with: track,
                                                           transceiverInit: transceiverInit,
                                                           startBitrateKbps: startBitrateKbps)
            return RTCSender(transceiver.sender)
        }
    }

    @Test func seedsTheEstimatorOnceWithTheLargestHint() async throws {
        try await withTransport { transport in
            _ = try await addVideoSender(to: transport, startBitrateKbps: 1000)
            _ = try await addVideoSender(to: transport, startBitrateKbps: 3600)

            await transport.applyVideoStartBitrateIfNeeded()
            #expect(await transport.videoStartBitrateSeed == .seeded(kbps: 3600))

            // A later publish does not reseed an estimator that is already running.
            _ = try await addVideoSender(to: transport, startBitrateKbps: 4500)
            await transport.applyVideoStartBitrateIfNeeded()
            #expect(await transport.videoStartBitrateSeed == .seeded(kbps: 3600))
        }
    }

    @Test func waitsForTheFirstVideo() async throws {
        try await withTransport { transport in
            await transport.applyVideoStartBitrateIfNeeded()
            #expect(await transport.videoStartBitrateSeed == .pending)

            _ = try await addVideoSender(to: transport, startBitrateKbps: 720)
            await transport.applyVideoStartBitrateIfNeeded()
            #expect(await transport.videoStartBitrateSeed == .seeded(kbps: 720))
        }
    }

    /// Once a video without a hint is flowing, its traffic drives the estimate, so a later video
    /// with a hint must not reset it.
    @Test func leavesTheEstimatorAloneWhenTheFirstVideoHasNoHint() async throws {
        try await withTransport { transport in
            _ = try await addVideoSender(to: transport, startBitrateKbps: nil)
            await transport.applyVideoStartBitrateIfNeeded()
            #expect(await transport.videoStartBitrateSeed == .skipped)

            _ = try await addVideoSender(to: transport, startBitrateKbps: 1000)
            await transport.applyVideoStartBitrateIfNeeded()
            #expect(await transport.videoStartBitrateSeed == .skipped)
        }
    }

    @Test func seedsOnceTheOfferWithVideoIsSent() async throws {
        try await withTransport { transport in
            await transport.set(onOfferBlock: { _, _ in })
            _ = try await addVideoSender(to: transport, startBitrateKbps: 1000)

            try await transport.createAndSendOffer()

            #expect(await transport.videoStartBitrateSeed == .seeded(kbps: 1000))
        }
    }

    /// A negotiation that fails before its offer is sent must not use up the seed.
    @Test func keepsTheSeedWhenTheOfferIsNotSent() async throws {
        try await withTransport { transport in
            await transport.set(onOfferBlock: { _, _ in throw LiveKitError(.invalidState, message: "Offer not sent") })
            _ = try await addVideoSender(to: transport, startBitrateKbps: 1000)

            await #expect(throws: LiveKitError.self) {
                try await transport.createAndSendOffer()
            }

            #expect(await transport.videoStartBitrateSeed == .pending)
        }
    }

    @Test func ignoresARemovedSender() async throws {
        try await withTransport { transport in
            let screenShare = try await addVideoSender(to: transport, startBitrateKbps: 3600)
            _ = try await addVideoSender(to: transport, startBitrateKbps: 1000)

            try await transport.remove(track: screenShare)

            await transport.applyVideoStartBitrateIfNeeded()
            #expect(await transport.videoStartBitrateSeed == .seeded(kbps: 1000))
        }
    }
}
