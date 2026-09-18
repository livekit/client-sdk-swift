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
        /// A few large frames that require DTP packetization across multiple packets.
        static let largeFrames = ReceiveScenario(name: "largeFrames", payloadSize: 196 * 1024, frameCount: 3, interFrameDelayMs: 100)
    }

    /// Pushes each frame only once the previous one has arrived, retrying a frame that is lost.
    ///
    /// Two things this deliberately does not do.
    ///
    /// It does not push a burst. The `_data_track` channel is drop-oldest with room for exactly one
    /// queued frame, and its buffered-amount low-water mark is 8 KiB — small on purpose, so at most
    /// one message is handed to SCTP at a time (`DATA_TRACK_BUFFERED_AMOUNT_LOW_THRESHOLD` in
    /// rust-sdks: "data tracks prefer dropping packets over queueing"). A producer that outruns the
    /// channel is *supposed* to lose the frames waiting behind the one in flight, so the old burst
    /// measured how loaded the runner was rather than anything about the SDK.
    ///
    /// It does not require a frame to arrive on its first attempt either. The channel is unordered
    /// and never retransmits, and a frame this size spans many packets, so losing one loses the
    /// frame. Retrying against a deadline keeps what is actually being covered — packetization,
    /// reassembly and integrity of a whole frame — while leaving the transport free to behave like
    /// the best-effort transport it is. A regression still fails: nothing ever arrives.
    private func pushAndReceive(_ scenario: ReceiveScenario, on fixture: DataTrackFixture) async throws {
        let stream = try await fixture.remoteTrack.subscribe()
        let payload = Data(repeating: 0xAB, count: scenario.payloadSize)

        for index in 0 ..< scenario.frameCount {
            // Few, long attempts rather than many short ones: a timed-out `next(within:)` cannot
            // cancel the UniFFI read under it, so every retry leaves one more read outstanding on
            // the stream.
            var received: Data?
            let deadline = Date().addingTimeInterval(30)
            while received == nil, Date() < deadline {
                try fixture.track.tryPush(frame: .now(payload: payload))
                received = await stream.next(within: 10)?.payload
            }
            #expect(received == payload, "Frame \(index) did not arrive intact")
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

            let frame = try #require(await stream.next(within: 15))
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
                let frame = try #require(await stream.next(within: 15), "No frame on first subscription")
                #expect(frame.payload == payload)
            }
            // Stream dropped — unsubscribes.

            // Small delay to let unsubscribe propagate.
            try await Task.sleep(nanoseconds: 500_000_000)

            // Second subscription.
            do {
                let stream = try await remoteTrack.subscribe()
                try track.tryPush(frame: DataTrackFrame(payload: payload))
                let frame = try #require(await stream.next(within: 15), "No frame on second subscription")
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

            let received = await stream.collect(frameCount - 1)
            #expect(received.count >= frameCount - 1)
            #expect(received.allSatisfy { $0.payload == payload })
        }
    }
}
