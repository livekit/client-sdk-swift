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

/// ``Transport/receivedMedia(applying:)`` — the scan that replaces `didAddTrack` in single PC
/// mode. It keeps no record of what it has reported, so a binding the room could not use yet
/// stays recoverable: the publication naming a track can arrive after the answer that binds it,
/// and an unsubscribe clears a publication whose section the server then reuses.
@Suite(.tags(.media))
struct ReceivedMediaScanTests {
    private final class StubTransportDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
        func transport(_: Transport, didRemoveTrackWithId _: String) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    /// A transport whose receive sections have mids, which only exist once a local description
    /// has been applied.
    private func withNegotiatedReceiveSections(_ body: (Transport, [String]) async throws -> Void) async throws {
        let transport = try await Transport(config: .liveKitDefault(),
                                            target: .publisher,
                                            primary: true,
                                            singlePCMode: true,
                                            delegate: StubTransportDelegate())
        do {
            try await RTC.run {
                let recv = LKRTCRtpTransceiverInit()
                recv.direction = .recvOnly
                _ = try transport.addTransceiver(ofType: .audio, transceiverInit: recv)
                _ = try transport.addTransceiver(ofType: .video, transceiverInit: recv)
            }
            let offer = try await transport.createOffer()
            try await transport.set(localDescription: offer)

            let mids = SDP(parsing: offer.sdp).mediaSections.compactMap(\.mid).filter { !$0.isEmpty }
            try await body(transport, mids)
        } catch {
            await transport.close()
            throw error
        }
        await transport.close()
    }

    @Test func reportsABoundSection() async throws {
        try await withNegotiatedReceiveSections { transport, mids in
            let mid = try #require(mids.first)
            let sid = Track.Sid(from: "TR_first")

            let first = await transport.receivedMedia(applying: [mid: sid])
            #expect(first.count == 1)
            #expect(first.first?.trackSid == sid)
        }
    }

    /// The recovery path. The room may not be able to use a binding when it first appears — the
    /// publication has not arrived, or an unsubscribe cleared it — so every scan has to keep
    /// offering it. A scan that reported each binding once would lose it in both cases.
    @Test func keepsReportingABindingOnEveryScan() async throws {
        try await withNegotiatedReceiveSections { transport, mids in
            let mid = try #require(mids.first)
            let sid = Track.Sid(from: "TR_deferred")

            #expect(await transport.receivedMedia(applying: [mid: sid]).count == 1)

            // An empty mapping, as a participant update supplies: the scan works from the
            // mapping it already holds.
            let again = await transport.receivedMedia(applying: [:])
            #expect(again.count == 1, "a binding must stay on offer until the room takes it")
            #expect(again.first?.trackSid == sid)
        }
    }

    /// The mapping accumulates: an answer naming one mid is not a statement that the others
    /// became unbound.
    @Test func mappingIsMergedAcrossDescriptions() async throws {
        try await withNegotiatedReceiveSections { transport, mids in
            try #require(mids.count >= 2)
            _ = await transport.receivedMedia(applying: [mids[0]: Track.Sid(from: "TR_a")])

            let second = await transport.receivedMedia(applying: [mids[1]: Track.Sid(from: "TR_b")])
            #expect(second.count == 2, "naming one mid must not retire the others")
            #expect(Set(second.map(\.trackSid)) == [Track.Sid(from: "TR_a"), Track.Sid(from: "TR_b")])
        }
    }

    /// A room move rebuilds every publication on the same peer connection, so a section carried
    /// over unchanged has to be offered again rather than read as already attached.
    @Test func forgetReceivedMediaDropsTheMapping() async throws {
        try await withNegotiatedReceiveSections { transport, mids in
            let mid = try #require(mids.first)
            let sid = Track.Sid(from: "TR_moved")
            #expect(await transport.receivedMedia(applying: [mid: sid]).count == 1)

            await transport.forgetReceivedMedia()

            // The mapping went with it, so the server has to name the binding again.
            #expect(await transport.receivedMedia(applying: [:]).isEmpty)
            #expect(await transport.receivedMedia(applying: [mid: sid]).count == 1)
        }
    }
}
