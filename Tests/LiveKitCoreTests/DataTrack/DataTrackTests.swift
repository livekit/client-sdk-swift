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

    @Test(arguments: [ReceiveScenario.smallFrames, .largeFrames])
    func publishAndReceive(_ scenario: ReceiveScenario) async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisherRoom = rooms[0]
            let subscriberRoom = rooms[1]

            // Start watching before publishing to avoid a race.
            let watcher = DataTrackWatcher(expectedName: "test")
            subscriberRoom.delegates.add(delegate: watcher)

            let track = try await publisherRoom.localParticipant.publishDataTrack(name: "test")
            #expect(track.isPublished)

            let remoteTrack = try await watcher.waitForTrack()
            #expect(remoteTrack.info.name == "test")
            // withRooms enables E2EE by default, so the track should be encrypted.
            #expect(remoteTrack.info.usesE2ee)

            let stream = try await remoteTrack.subscribe()

            let payload = Data(repeating: 0xAB, count: scenario.payloadSize)
            for _ in 0 ..< scenario.frameCount {
                try track.tryPush(frame: .now(payload: payload))
                if scenario.interFrameDelayMs > 0 {
                    try? await Task.sleep(nanoseconds: scenario.interFrameDelayMs * 1_000_000)
                }
            }

            // The channel is unreliable, so tolerate a single dropped frame.
            let expected = scenario.frameCount - 1
            let received = await stream.collect(expected)
            #expect(received.count >= expected, "Expected at least \(expected) frames, got \(received.count)")
            #expect(received.allSatisfy { $0.payload == payload }, "Payload mismatch")
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
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisherRoom = rooms[0]
            let subscriberRoom = rooms[1]

            let watcher = DataTrackWatcher(expectedName: "ts-test")
            subscriberRoom.delegates.add(delegate: watcher)

            let track = try await publisherRoom.localParticipant.publishDataTrack(name: "ts-test")
            let remoteTrack = try await watcher.waitForTrack()
            let stream = try await remoteTrack.subscribe()

            let payload = Data([1, 2, 3])
            try track.tryPush(frame: .now(payload: payload))

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
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisherRoom = rooms[0]
            let subscriberRoom = rooms[1]

            let watcher = DataTrackWatcher(expectedName: "resub")
            subscriberRoom.delegates.add(delegate: watcher)

            let track = try await publisherRoom.localParticipant.publishDataTrack(name: "resub")
            let remoteTrack = try await watcher.waitForTrack()

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
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "seq")
            rooms[1].delegates.add(delegate: watcher)

            let track = try await rooms[0].localParticipant.publishDataTrack(name: "seq")
            let remoteTrack = try await watcher.waitForTrack()
            let stream = try await remoteTrack.subscribe()

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
