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

/// WARP is offered unconditionally; the server decides whether it engages.
@Suite(.tags(.networking)) struct WARPTests {
    private final class StubDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
        func transport(_: Transport, didRemoveTrackWithId _: String) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    @Test func offerAdvertisesSPEDAndSNAP() async throws {
        let transport = try await Transport(config: .liveKitDefault(),
                                            target: .publisher,
                                            primary: true,
                                            delegate: StubDelegate())
        defer { Task { await transport.close() } }

        _ = await transport.dataChannel(for: LKRTCDataChannel.Labels.reliable,
                                        configuration: RTC.createDataChannelConfiguration())
        let sdp = try await transport.createOffer().sdp

        #expect(sdp.contains("goog-sped-v1"), "SPED: the WebRTC-IceHandshakeDtls field trial")
        #expect(sdp.contains("a=sctp-init:"), "SNAP: enableSctpSnap")
    }
}
