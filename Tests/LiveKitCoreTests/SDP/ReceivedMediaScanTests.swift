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
/// mode. What matters is not that it reports a binding once, but that a binding the room could
/// not use yet stays recoverable: the publication naming a track can arrive after the answer
/// that binds it, and an answer is not guaranteed to come again.
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

    @Test func reportsABoundSectionOnceAndNotAgain() async throws {
        try await withNegotiatedReceiveSections { transport, mids in
            let mid = try #require(mids.first)
            let sid = Track.Sid(from: "TR_first")

            let first = await transport.receivedMedia(applying: [mid: sid])
            #expect(first.count == 1)
            #expect(first.first?.trackSid == sid)

            // A later description repeats the binding; the room already has it.
            #expect(await transport.receivedMedia(applying: [mid: sid]).isEmpty)
        }
    }

    /// The recovery path: the room could not attach it yet, so the next scan must offer it again.
    /// Without this the binding is lost, because nothing re-reports a section once dispatched.
    @Test func undispatchedSectionIsReportedByTheNextScan() async throws {
        try await withNegotiatedReceiveSections { transport, mids in
            let mid = try #require(mids.first)
            let sid = Track.Sid(from: "TR_deferred")

            #expect(await transport.receivedMedia(applying: [mid: sid]).count == 1)
            await transport.undispatch(mid: mid, trackSid: sid)

            // An empty mapping, as a participant update supplies: the scan has to work from the
            // mapping it already holds.
            let again = await transport.receivedMedia(applying: [:])
            #expect(again.count == 1, "an undispatched binding must be offered again")
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
            #expect(second.count == 1, "naming one mid must not retire the others")
            #expect(second.first?.trackSid == Track.Sid(from: "TR_b"))
        }
    }

    /// A room move rebuilds every publication on the same peer connection, so a section carried
    /// over unchanged has to be offered again rather than read as already attached.
    @Test func forgetReceivedMediaMakesEverythingReportableAgain() async throws {
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
