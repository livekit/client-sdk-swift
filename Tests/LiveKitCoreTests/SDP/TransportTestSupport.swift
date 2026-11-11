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

/// A `TransportDelegate` that ignores everything, for tests that drive a `Transport` directly.
final class StubTransportDelegate: TransportDelegate {
    func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
    func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
    func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
    func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
    func transport(_: Transport, didRemoveTrackWithId _: String) {}
    func transportShouldNegotiate(_: Transport) {}
}

/// Builds a `Transport` and closes it when `body` returns or throws.
///
/// `defer { Task { await transport.close() } }` does not await the close, so the peer connection
/// can outlive the test and its blocking teardown lands on whatever runs next.
func withLiveTransport(target: Livekit_SignalTarget = .publisher,
                       primary: Bool = true,
                       singlePCMode: Bool = false,
                       _ body: (Transport) async throws -> Void) async throws
{
    let transport = try await Transport(config: .liveKitDefault(),
                                        target: target,
                                        primary: primary,
                                        singlePCMode: singlePCMode,
                                        delegate: StubTransportDelegate())
    do {
        try await body(transport)
    } catch {
        await transport.close()
        throw error
    }
    await transport.close()
}

/// Completes one offer/answer exchange against a throwaway peer, leaving `transport` in
/// `stable`.
///
/// A renegotiation cannot be tested from `have-local-offer`: `Transport.negotiate` queues one
/// until the current exchange finishes, so an offer created there is not the offer the SDK would
/// actually send.
func settleOfferAnswer(_ transport: Transport, offer: LKRTCSessionDescription) async throws {
    try await withLiveTransport(target: .subscriber, primary: false) { answerer in
        try await transport.set(localDescription: offer)
        try await answerer.set(remoteDescription: offer)
        let answer = try await answerer.createAnswer()
        try await answerer.set(localDescription: answer)
        try await transport.set(remoteDescription: answer)
    }
}
