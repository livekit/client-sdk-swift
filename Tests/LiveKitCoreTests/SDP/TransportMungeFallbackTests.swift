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

/// Runs against a real (local, offline) peer connection to prove the fallback premise
/// on the shipped libwebrtc binary: a rejected `setLocalDescription` reports an error
/// without poisoning the peer connection, so retrying with less-munged SDP works.
@Suite(.tags(.media))
struct TransportMungeFallbackTests {
    private final class StubTransportDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
        func transport(_: Transport, didRemoveTrackWithId _: String) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    /// Runs `body` with a live transport carrying a receive-only audio transceiver
    /// (so offers contain a real Opus section for the munges to edit), closing it even
    /// when `body` throws so a failed test doesn't leak a peer connection into the
    /// rest of the parallel run.
    private func withTransport(_ body: (Transport) async throws -> Void) async throws {
        let transport = try await Transport(config: .liveKitDefault(),
                                            target: .publisher,
                                            primary: true,
                                            delegate: StubTransportDelegate())
        do {
            let transceiverInit = LKRTCRtpTransceiverInit()
            transceiverInit.direction = .recvOnly
            try await RTC.run { _ = try transport.addTransceiver(ofType: .audio, transceiverInit: transceiverInit) }
            try await body(transport)
        } catch {
            await transport.close()
            throw error
        }
        await transport.close()
    }

    @Test func rejectedLocalDescriptionLeavesPeerConnectionUsable() async throws {
        try await withTransport { transport in
            let offer = try await transport.createOffer()
            let garbage = RTC.createSessionDescription(type: .offer, sdp: "this is not sdp")

            await #expect(throws: (any Error).self) {
                try await transport.set(localDescription: garbage)
            }
            try await transport.set(localDescription: offer)
        }
    }

    @Test func appliesTheMungedDescriptionWhenAccepted() async throws {
        try await withTransport { transport in
            let offer = try await transport.createOffer()

            let applied = try await transport.set(localDescription: offer,
                                                  munging: [Transport.mungeOpusStereoForAllAudio])

            #expect(applied !== offer)
            #expect(applied.sdp == Transport.mungeOpusStereoForAllAudio(offer.sdp))
        }
    }

    /// A no-op composition must set the original directly — object identity proves the
    /// munged path (which would wrap the SDP in a new description) was never taken.
    @Test func noOpMungesSetTheOriginalDirectly() async throws {
        try await withTransport { transport in
            let offer = try await transport.createOffer()

            let untouched = try await transport.set(localDescription: offer, munging: [])
            let identity = try await transport.set(localDescription: offer, munging: [{ $0 }])

            #expect(untouched === offer)
            #expect(identity === offer)
        }
    }

    @Test func fallsBackToTheOriginalWhenEveryMungeIsRejected() async throws {
        try await withTransport { transport in
            let offer = try await transport.createOffer()

            let applied = try await transport.set(localDescription: offer,
                                                  munging: [{ _ in "this is not sdp" }])

            #expect(applied === offer)
        }
    }

    /// Munges are dropped from the right on rejection, so a rejected optional munge
    /// (here: garbage) cannot revert the required one before it (here: stereo, standing
    /// in for the single-PC direction rewrite).
    @Test func rejectionDropsOnlyTheTailMunge() async throws {
        try await withTransport { transport in
            let offer = try await transport.createOffer()

            let applied = try await transport.set(localDescription: offer, munging: [
                Transport.mungeOpusStereoForAllAudio,
                { _ in "this is not sdp" },
            ])

            #expect(applied.sdp == Transport.mungeOpusStereoForAllAudio(offer.sdp))
            #expect(applied.sdp != offer.sdp)
        }
    }

    // MARK: - Video start bitrate

    /// The premise of ``Transport/mungeVideoStartBitrate(_:kbpsBySenderId:)`` on the shipped
    /// libwebrtc: a send-only video section's `a=msid` carries the sender id (so the map is
    /// keyed correctly), and a local offer with `x-google-start-bitrate` set on every video
    /// codec — inserted for VP8, appended for the rest — is accepted rather than rejected as
    /// disallowed munging.
    @Test func acceptsVideoStartBitrateMungedIntoTheOffer() async throws {
        try await withTransport { transport in
            let transceiverInit = LKRTCRtpTransceiverInit()
            transceiverInit.direction = .sendOnly
            let senderId = try await RTC.run {
                try transport.addTransceiver(ofType: .video, transceiverInit: transceiverInit).sender.senderId
            }
            let offer = try await transport.createOffer()

            let video = try #require(SDP(parsing: offer.sdp).mediaSections.first { $0.mediaType == "video" })
            #expect(video.msidTrackId == senderId)

            let munged = Transport.mungeVideoStartBitrate(offer.sdp, kbpsBySenderId: [senderId: 1000])
            let applied = try await transport.set(localDescription: offer, munging: [
                { Transport.mungeVideoStartBitrate($0, kbpsBySenderId: [senderId: 1000]) },
            ])

            #expect(munged != offer.sdp)
            #expect(applied.sdp == munged)
            let appliedVideo = try #require(SDP(parsing: applied.sdp).mediaSections.first { $0.mediaType == "video" })
            for rtpmap in appliedVideo.rtpmaps where Transport.startBitrateCodecs.contains(rtpmap.codec.uppercased()) {
                #expect(appliedVideo.fmtp(forPayload: rtpmap.payload)?.parameters.contains("x-google-start-bitrate=1000") == true,
                        "payload \(rtpmap.payload) (\(rtpmap.codec))")
            }
        }
    }

    /// Two publisher offers on one peer connection, answered by a second local peer
    /// connection: the first offer carrying local video gets the connection-level hint; a
    /// later offer — here adding an uncapped screen-share sender with a larger hint — must
    /// not write it again, since rewriting a changed value would restart libwebrtc's
    /// converged bandwidth estimator.
    @Test func writesTheStartBitrateOnceForTheConnection() async throws {
        let answerer = try await Transport(config: .liveKitDefault(), target: .subscriber, primary: false, delegate: StubTransportDelegate())
        defer { Task { await answerer.close() } }
        try await withTransport { publisher in
            let offers = OfferBox()
            await publisher.set(onOfferBlock: { offer, _ in await offers.append(offer) })

            func publishVideo(startBitrateKbps: Int) async throws -> String {
                try await RTC.run {
                    let transceiverInit = LKRTCRtpTransceiverInit()
                    transceiverInit.direction = .sendOnly
                    let track = RTC.createVideoTrack(source: RTC.createVideoSource(forScreenShare: false))
                    return try publisher.addTransceiver(with: track, transceiverInit: transceiverInit, startBitrateKbps: startBitrateKbps).sender.senderId
                }
            }
            func startBitrates(in sdp: String, senderId: String) throws -> Set<String> {
                let section = try #require(SDP(parsing: sdp).mediaSections.first { $0.msidTrackId == senderId })
                return Set(section.fmtps.flatMap(\.parameters).filter { $0.hasPrefix("x-google-start-bitrate=") })
            }

            let camera = try await publishVideo(startBitrateKbps: 1000)
            try await publisher.createAndSendOffer()
            let first = try #require(await offers.all.first)
            #expect(try startBitrates(in: first.sdp, senderId: camera) == ["x-google-start-bitrate=1000"])

            try await answerer.set(remoteDescription: first)
            let answer = try await answerer.createAnswer()
            try await answerer.set(localDescription: answer)
            try await publisher.set(remoteDescription: answer)

            let share = try await publishVideo(startBitrateKbps: 4500)
            try await publisher.createAndSendOffer()
            let second = try #require(await offers.all.last)
            #expect(await offers.all.count == 2)
            #expect(try startBitrates(in: second.sdp, senderId: share).isEmpty)
            #expect(!second.sdp.contains("x-google-start-bitrate=4500"))
        }
    }

    private actor OfferBox {
        private(set) var all: [LKRTCSessionDescription] = []
        func append(_ offer: LKRTCSessionDescription) { all.append(offer) }
    }
}
