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
/// without poisoning the peer connection, so retrying with the original SDP works.
@Suite(.tags(.media))
struct TransportMungeFallbackTests {
    private final class StubTransportDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: LKRTCMediaStreamTrack, rtpReceiver _: LKRTCRtpReceiver, streams _: [LKRTCMediaStream]) {}
        func transport(_: Transport, didRemoveTrack _: LKRTCMediaStreamTrack) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    /// Runs `body` with a live transport, closing it even when `body` throws so a
    /// failed test doesn't leak a peer connection into the rest of the parallel run.
    private func withTransport(_ body: (Transport) async throws -> Void) async throws {
        let transport = try Transport(config: .liveKitDefault(),
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

    @Test func fallsBackToOriginalWhenMungedDescriptionIsRejected() async throws {
        try await withTransport { transport in
            let offer = try await transport.createOffer()
            let garbage = RTC.createSessionDescription(type: .offer, sdp: "this is not sdp")

            let applied = try await transport.set(mungedLocalDescription: garbage, fallingBackTo: offer)

            #expect(applied.sdp == offer.sdp)
        }
    }

    @Test func appliesMungedDescriptionWhenAccepted() async throws {
        try await withTransport { transport in
            let offer = try await transport.createOffer()
            let munged = RTC.createSessionDescription(type: offer.type, sdp: offer.sdp)

            let applied = try await transport.set(mungedLocalDescription: munged, fallingBackTo: offer)

            #expect(applied === munged)
        }
    }
}
