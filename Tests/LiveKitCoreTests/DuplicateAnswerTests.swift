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

/// A proxy can deliver a second copy of an answer that was already applied. By then there is
/// no local offer left to answer, so applying it again is invalid.
@Suite(.tags(.networking)) struct DuplicateAnswerTests {
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

    private func answer(to offer: LKRTCSessionDescription) async throws -> LKRTCSessionDescription {
        let peer = StubDelegate()
        let remote = try await makeTransport(singlePCMode: false, delegate: peer)
        defer { Task { await remote.close() } }

        try await remote.set(remoteDescription: offer)
        let answer = try await remote.createAnswer()
        try await remote.set(localDescription: answer)
        return answer
    }

    /// The second copy carries the same offerId, so the existing stale-offer check passes it
    /// through. It must be dropped on the duplicate rule instead of reaching the connection.
    @Test func duplicateAnswerIsIgnored() async throws {
        let delegate = StubDelegate()
        let transport = try await makeTransport(singlePCMode: true, delegate: delegate)
        defer { Task { await transport.close() } }

        _ = await transport.dataChannel(for: LKRTCDataChannel.Labels.reliable,
                                        configuration: RTC.createDataChannelConfiguration())

        let initial = try await transport.createInitialOffer()
        let offer = try #require(initial)

        let answer = try await answer(to: offer.offer)
        try await transport.set(remoteDescription: answer, offerId: offer.offerId)
        #expect(await transport.signalingState == .stable)

        let appliedSdp = await transport.remoteDescription?.sdp

        // The same answer again, exactly as a proxy would repeat it.
        try await transport.set(remoteDescription: answer, offerId: offer.offerId)

        #expect(await transport.signalingState == .stable)
        #expect(await transport.remoteDescription?.sdp == appliedSdp)
    }

    /// Only repeats are dropped: the answer to an offer still awaiting one must apply.
    @Test func answerToAPendingOfferStillApplies() async throws {
        let delegate = StubDelegate()
        let transport = try await makeTransport(singlePCMode: true, delegate: delegate)
        defer { Task { await transport.close() } }

        _ = await transport.dataChannel(for: LKRTCDataChannel.Labels.reliable,
                                        configuration: RTC.createDataChannelConfiguration())

        let initial = try await transport.createInitialOffer()
        let offer = try #require(initial)

        // The deferred initial offer leaves the connection `.stable`, so the duplicate rule
        // has to treat a pending initial offer as an outstanding one.
        #expect(await transport.signalingState == .stable)

        let answer = try await answer(to: offer.offer)
        try await transport.set(remoteDescription: answer, offerId: offer.offerId)

        #expect(await transport.remoteDescription != nil)
        #expect(await transport.localDescription != nil)
    }
}
