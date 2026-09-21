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
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.dataTrack, .e2e))
struct DataTrackTests {
    // MARK: - Publish and Receive

    /// A publish → subscribe → push → receive scenario.
    struct ReceiveScenario: CustomTestStringConvertible {
        let name: String
        let payloadSize: Int
        let frameCount: Int
        /// Delay between pushes; large multi-packet frames need spacing.
        let interFrameDelayMs: UInt64
        var testDescription: String { name }

        /// Many small single-packet frames.
        static let smallFrames = ReceiveScenario(name: "smallFrames", payloadSize: 1024, frameCount: 10, interFrameDelayMs: 0)
        /// A few large frames that require DTP packetization across multiple packets. 64 KiB is
        /// five packets at the pipeline's 16 KB MTU, which covers packetization and reassembly
        /// while keeping the odds of a drop low — this asserts *every* frame, on a channel that
        /// never retransmits, so one lost packet is one failed test.
        static let largeFrames = ReceiveScenario(name: "largeFrames", payloadSize: 64 * 1024, frameCount: 3, interFrameDelayMs: 100)
    }

    /// Pushes each frame only once the previous one has arrived.
    ///
    /// Not a burst, deliberately. The `_data_track` channel is drop-oldest with room for exactly one
    /// queued frame, and its buffered-amount low-water mark is 8 KiB — small on purpose, so at most
    /// one message is handed to SCTP at a time (`DATA_TRACK_BUFFERED_AMOUNT_LOW_THRESHOLD` in
    /// rust-sdks: "data tracks prefer dropping packets over queueing"). A producer that outruns the
    /// channel is *supposed* to lose the frames waiting behind the one in flight, so the old burst
    /// plus "tolerate one drop" measured how loaded the runner was rather than anything about the
    /// SDK.
    ///
    /// Each frame is re-pushed until one copy arrives intact, for up to 15 s, because a
    /// multi-packet frame to a slow subscriber is lost far more often than not. The SFU queues at
    /// most 8 KiB per subscriber before it drops (`data dropped due to high buffered amount:
    /// buffered amount 22720, min buffered amount 8192` in CI's server log, seven times for this
    /// track on one leg), so whenever a packet reaches it while the subscriber has not yet
    /// acknowledged the previous one, that packet is gone — and a five-packet frame needs four
    /// such acknowledgements in a row. Three pushes ten seconds apart all lost on that leg; many
    /// cheap pushes let one land in the gaps. What this asserts is that a frame *can* be
    /// packetized, forwarded, reassembled and decrypted intact, which one arrival per frame
    /// proves; a frame that never arrives in 15 s of trying still fails.
    ///
    /// Read through a ``DataTrackReader``, which owns the stream's single `next()` caller. Reading
    /// the stream directly more than once cannot work: a bounded read that times out leaves a
    /// `next()` holding the Rust-side mutex, and every later read blocks behind it — so one lost
    /// frame used to take the rest of the test with it and look like total delivery failure.
    private func pushAndReceive(_ scenario: ReceiveScenario, on fixture: DataTrackFixture) async throws {
        let reader = try await fixture.remoteTrack.subscribe().reader()
        let payload = Data(repeating: 0xAB, count: scenario.payloadSize)

        for index in 0 ..< scenario.frameCount {
            let deadline = Date().addingTimeInterval(15)
            var frame: DataTrackFrame?
            repeat {
                try fixture.track.tryPush(frame: .now(payload: payload))
                frame = await reader.next(within: 0.5)
            } while frame == nil && Date() < deadline
            #expect(frame?.payload == payload, "Frame \(index) did not arrive intact")
        }
    }

    @Test(arguments: [ReceiveScenario.smallFrames, .largeFrames])
    func publishAndReceive(_ scenario: ReceiveScenario) async throws {
        try await TestEnvironment.withPublishedDataTrack { fixture in
            #expect(fixture.track.isPublished)
            #expect(fixture.remoteTrack.info.name == "test")
            // withRooms enables E2EE by default, so the track should be encrypted.
            #expect(fixture.remoteTrack.info.usesE2ee)

            try await pushAndReceive(scenario, on: fixture)
        }
    }

    // MARK: - Published State

    @Test
    func publishedState() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let room = rooms[0]
            let track = try await room.localParticipant.publishDataTrack(name: "state-test")
            #expect(track.isPublished)

            track.unpublish()
            await track.waitForUnpublish()
            #expect(!track.isPublished)
        }
    }

    // MARK: - Frame Timestamp

    @Test
    func frameTimestamp() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "ts-test") { fixture in
            let stream = try await fixture.remoteTrack.subscribe()

            let payload = Data([1, 2, 3])
            try fixture.track.tryPush(frame: .now(payload: payload))

            let frame = try #require(await stream.firstFrame(within: 15))
            let ts = try #require(frame.userTimestamp)
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            let elapsedMs = nowMs > ts ? nowMs - ts : 0
            #expect(elapsedMs < 5000, "Latency should be under 5 seconds, was \(elapsedMs)ms")
        }
    }

    // MARK: - Resubscribe

    @Test
    func resubscribe() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "resub") { fixture in
            let track = fixture.track
            let remoteTrack = fixture.remoteTrack

            let payload = Data([0xDE, 0xAD])

            // First subscription.
            do {
                let stream = try await remoteTrack.subscribe()
                try track.tryPush(frame: DataTrackFrame(payload: payload))
                let frame = try #require(await stream.firstFrame(within: 15), "No frame on first subscription")
                #expect(frame.payload == payload)
            }
            // Stream dropped — unsubscribes.

            // Let the SFU finish the unsubscribe before asking again. Its subscription manager
            // reconciles the unsubscribe asynchronously and then deletes the subscription entry;
            // a subscribe that lands in between flips the entry's desired flag and is deleted
            // with it, so the request is logged (`subscribing to data track`) but never executed
            // (livekit-server `reconcileDataTrackSubscription`, seen in CI's server log). The
            // Rust side then waits on a pending subscription that nothing will answer — and a
            // repeated `subscribe()` joins that same pending list rather than sending a new
            // request, so retrying cannot recover it. Only distance from the unsubscribe can.
            try await Task.sleep(nanoseconds: 2_000_000_000)

            // Second subscription.
            do {
                let stream = try await remoteTrack.subscribe()
                try track.tryPush(frame: DataTrackFrame(payload: payload))
                let frame = try #require(await stream.firstFrame(within: 15), "No frame on second subscription")
                #expect(frame.payload == payload)
            }
        }
    }

    // MARK: - Send AsyncSequence

    @Test
    func sendContentsOfSequence() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "seq") { fixture in
            let track = fixture.track
            let stream = try await fixture.remoteTrack.subscribe()

            let frameCount = 5
            let payload = Data([0x01, 0x02])
            let (source, continuation) = AsyncStream.makeStream(of: DataTrackFrame.self)
            for _ in 0 ..< frameCount {
                continuation.yield(DataTrackFrame(payload: payload))
            }
            continuation.finish()

            try await track.send(contentsOf: source)

            let received = await stream.reader().collect(frameCount - 1)
            #expect(received.count >= frameCount - 1)
            #expect(received.allSatisfy { $0.payload == payload })
        }
    }
}
