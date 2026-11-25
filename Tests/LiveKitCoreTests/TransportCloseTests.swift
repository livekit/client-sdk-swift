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

/// A closed transport must refuse new transceivers instead of handing them to its closed
/// peer connection.
@Suite(.tags(.media))
struct TransportCloseTests {
    private final class StubTransportDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
        func transport(_: Transport, didRemoveTrackWithId _: String) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    @Test(arguments: [LKRTCRtpMediaType.audio, .video])
    func addTransceiverAfterCloseThrows(mediaType: LKRTCRtpMediaType) async throws {
        let transport = try await Transport(config: .liveKitDefault(),
                                            target: .publisher,
                                            primary: true,
                                            delegate: StubTransportDelegate())
        await transport.close()

        let trackError = await #expect(throws: LiveKitError.self) {
            try await RTC.run {
                let factory = RTC.peerConnectionFactory
                let track: LKRTCMediaStreamTrack = mediaType == .audio
                    ? factory.audioTrack(with: factory.audioSource(with: nil), trackId: "audio")
                    : factory.videoTrack(with: factory.videoSource(forScreenCast: false), trackId: "video")
                _ = try transport.addTransceiver(with: track, transceiverInit: LKRTCRtpTransceiverInit())
            }
        }
        #expect(trackError?.type == .invalidState)

        let typeError = await #expect(throws: LiveKitError.self) {
            try await RTC.run { _ = try transport.addTransceiver(ofType: mediaType, transceiverInit: LKRTCRtpTransceiverInit()) }
        }
        #expect(typeError?.type == .invalidState)
    }
}
