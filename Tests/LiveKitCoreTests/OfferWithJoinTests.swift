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

/// Covers the offer bundled with the JOIN request: the deferral of `setLocalDescription`
/// until the answer arrives, and the offer's trip through the join_request parameter.
@Suite(.tags(.networking)) struct OfferWithJoinTests {
    private static let url = URL(string: "wss://example.livekit.cloud")!

    /// Records nothing; `Transport` requires a delegate but none of these tests exercise it.
    private final class StubDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
        func transport(_: Transport, didRemoveTrackWithId _: String) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    private func makeTransport(singlePCMode: Bool, delegate: StubDelegate) async throws -> Transport {
        try await Transport(config: LKRTCConfiguration.liveKitDefault(),
                            target: .publisher,
                            primary: true,
                            singlePCMode: singlePCMode,
                            delegate: delegate)
    }

    /// The dual-PC flow has the server offer first, so there is nothing to bundle.
    @Test func noInitialOfferOutsideSinglePCMode() async throws {
        let delegate = StubDelegate()
        let transport = try await makeTransport(singlePCMode: false, delegate: delegate)
        defer { Task { await transport.close() } }

        let initial = try await transport.createInitialOffer()
        #expect(initial == nil)
    }

    /// The point of the whole mechanism: the offer is produced and signalled, but not applied,
    /// so ICE gathering cannot start before the server's ICE servers are installed.
    @Test func initialOfferIsDeferredUntilAnswer() async throws {
        let delegate = StubDelegate()
        let transport = try await makeTransport(singlePCMode: true, delegate: delegate)
        defer { Task { await transport.close() } }

        _ = await transport.dataChannel(for: LKRTCDataChannel.Labels.reliable,
                                        configuration: RTC.createDataChannelConfiguration())

        let initial = try await transport.createInitialOffer()
        let offer = try #require(initial)

        #expect(offer.offer.type == .offer)
        #expect(offer.offerId == 1, "The bundled offer must claim an id the answer can be matched against")
        #expect(!offer.offer.sdp.isEmpty)
        #expect(await transport.localDescription == nil, "setLocalDescription must be deferred")
        #expect(await transport.signalingState == .stable)

        // Answer it the way the SFU would, from a second peer connection.
        let answer = try await answer(to: offer.offer)
        try await transport.set(remoteDescription: answer, offerId: offer.offerId)

        #expect(await transport.localDescription != nil, "The deferred offer must be applied with the answer")
        #expect(await transport.remoteDescription != nil)
        #expect(await transport.signalingState == .stable)
    }

    /// A JOIN that never completes must not leave the transport wedged waiting for an answer
    /// to an offer nobody holds.
    @Test func clearingThePendingOfferRestoresOrdinaryNegotiation() async throws {
        let delegate = StubDelegate()
        let transport = try await makeTransport(singlePCMode: true, delegate: delegate)
        defer { Task { await transport.close() } }

        _ = try await transport.createInitialOffer()
        await transport.clearPendingInitialOffer()

        let sentOffers = SentOffers()
        await transport.set { offer, offerId in
            await sentOffers.append(offer: offer, offerId: offerId)
        }
        try await transport.negotiate(force: true)

        #expect(await sentOffers.count == 1, "Negotiation must proceed once the pending offer is cleared")
        #expect(await transport.localDescription != nil)
    }

    /// While an initial offer is outstanding the connection still reads `.stable`, so the
    /// deferred offer — not the signaling state — has to gate renegotiation.
    @Test func negotiationDefersWhileTheInitialOfferIsPending() async throws {
        let delegate = StubDelegate()
        let transport = try await makeTransport(singlePCMode: true, delegate: delegate)
        defer { Task { await transport.close() } }

        let initial = try await transport.createInitialOffer()
        let offer = try #require(initial)

        let sentOffers = SentOffers()
        await transport.set { offer, offerId in
            await sentOffers.append(offer: offer, offerId: offerId)
        }

        try await transport.negotiate(force: true)
        #expect(await sentOffers.count == 0, "Must not offer over the top of the bundled offer")

        // Applying the answer releases the queued renegotiation.
        let answer = try await answer(to: offer.offer)
        try await transport.set(remoteDescription: answer, offerId: offer.offerId)

        #expect(await sentOffers.count == 1)
    }

    @Test func joinRequestCarriesThePublisherOffer() throws {
        let sdp = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\n"
        let publisherOffer = Livekit_SessionDescription.with {
            $0.sdp = sdp
            $0.type = "offer"
            $0.id = 1
        }

        let url = try Utils.buildJoinRequestUrl(Self.url,
                                                connectOptions: ConnectOptions(),
                                                adaptiveStream: true,
                                                publisherOffer: publisherOffer)

        let joinRequest = try Self.decodeJoinRequest(from: url)
        #expect(joinRequest.hasPublisherOffer)
        #expect(joinRequest.publisherOffer.sdp == sdp)
        #expect(joinRequest.publisherOffer.type == "offer")
        #expect(joinRequest.publisherOffer.id == 1)
    }

    @Test func joinRequestOmitsTheOfferWhenThereIsNone() throws {
        let url = try Utils.buildJoinRequestUrl(Self.url,
                                                connectOptions: ConnectOptions(),
                                                adaptiveStream: true)

        let joinRequest = try Self.decodeJoinRequest(from: url)
        #expect(!joinRequest.hasPublisherOffer)
    }

    // MARK: - Helpers

    /// Accumulates offers handed to `Transport.set(onOfferBlock:)`.
    private actor SentOffers {
        private var offers: [(LKRTCSessionDescription, UInt32)] = []
        var count: Int { offers.count }
        func append(offer: LKRTCSessionDescription, offerId: UInt32) { offers.append((offer, offerId)) }
    }

    /// Answers `offer` from an independent peer connection, standing in for the SFU.
    private func answer(to offer: LKRTCSessionDescription) async throws -> LKRTCSessionDescription {
        let peer = StubDelegate()
        let remote = try await makeTransport(singlePCMode: false, delegate: peer)
        defer { Task { await remote.close() } }

        try await remote.set(remoteDescription: offer)
        let answer = try await remote.createAnswer()
        try await remote.set(localDescription: answer)
        return answer
    }

    private static func decodeJoinRequest(from url: URL) throws -> Livekit_JoinRequest {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let param = try #require(components.queryItems?.first { $0.name == "join_request" }?.value)
        let wrappedData = try #require(Data(base64URLEncoded: param))
        let wrapped = try Livekit_WrappedJoinRequest(serializedBytes: wrappedData)

        let joinRequestData: Data = switch wrapped.compression {
        case .gzip: try #require(TestGunzip.decompress(wrapped.joinRequest))
        default: wrapped.joinRequest
        }
        return try Livekit_JoinRequest(serializedBytes: joinRequestData)
    }
}
