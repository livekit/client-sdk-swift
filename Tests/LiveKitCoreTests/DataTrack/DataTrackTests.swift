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
            var received = 0
            for await frame in stream.values {
                #expect(frame.payload == payload, "Payload mismatch on frame \(received)")
                received += 1
                if received >= expected { break }
            }
            #expect(received >= expected, "Expected at least \(expected) frames, got \(received)")
        }
    }

    // MARK: - Publish Duplicate Name

    @Test
    func publishDuplicateName() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let room = rooms[0]
            let first = try await room.localParticipant.publishDataTrack(name: "dup")
            #expect(first.isPublished)
            await #expect(throws: DataTrackPublishError.self) {
                _ = try await room.localParticipant.publishDataTrack(name: "dup")
            }
        }
    }

    // MARK: - Publish Unauthorized

    @Test
    func publishUnauthorized() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: false),
        ]) { rooms in
            let room = rooms[0]
            await #expect(throws: DataTrackPublishError.self) {
                _ = try await room.localParticipant.publishDataTrack(name: "unauth")
            }
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

            let frame = try #require(await stream.next())
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
                let frame = try #require(await stream.next(), "No frame on first subscription")
                #expect(frame.payload == payload)
            }
            // Stream dropped — unsubscribes.

            // Small delay to let unsubscribe propagate.
            try await Task.sleep(nanoseconds: 500_000_000)

            // Second subscription.
            do {
                let stream = try await remoteTrack.subscribe()
                try track.tryPush(frame: DataTrackFrame(payload: payload))
                let frame = try #require(await stream.next(), "No frame on second subscription")
                #expect(frame.payload == payload)
            }
        }
    }

    // MARK: - Many Tracks

    @Test
    func publishManyTracks() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let room = rooms[0]
            let count = 64 // Conservative vs Rust's 256 — faster CI.

            var tracks: [LocalDataTrack] = []
            for i in 0 ..< count {
                let track = try await room.localParticipant.publishDataTrack(name: "track-\(i)")
                tracks.append(track)
            }

            #expect(tracks.count == count)
            for (i, track) in tracks.enumerated() {
                #expect(track.info.name == "track-\(i)")
                #expect(track.isPublished)
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

            var received = 0
            for await frame in stream.values {
                #expect(frame.payload == payload)
                received += 1
                if received >= frameCount - 1 { break }
            }
            #expect(received >= frameCount - 1)
        }
    }

    // MARK: - Attached to Remote Participant

    @Test
    func attachedToRemoteParticipant() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "attached")
            rooms[1].delegates.add(delegate: watcher)

            _ = try await rooms[0].localParticipant.publishDataTrack(name: "attached")
            let remoteTrack = try await watcher.waitForTrack()

            let publisherIdentity = try #require(rooms[0].localParticipant.identity)
            let publisher = try #require(rooms[1].remoteParticipants[publisherIdentity])
            #expect(publisher.dataTracks[remoteTrack.info.sid] != nil)
        }
    }

    // MARK: - Unpublish Delegate

    @Test
    func unpublishNotifiesDelegate() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "to-unpublish")
            rooms[1].delegates.add(delegate: watcher)

            let track = try await rooms[0].localParticipant.publishDataTrack(name: "to-unpublish")
            let remoteTrack = try await watcher.waitForTrack()

            track.unpublish()
            let unpublishedSid = try await watcher.waitForUnpublish()
            #expect(unpublishedSid == remoteTrack.info.sid)
        }
    }

    // MARK: - Join-Time Tracks

    /// A track published before a participant joins surfaces via the JoinResponse.
    @Test
    func receivesTrackPublishedBeforeJoin() async throws {
        let roomName = UUID().uuidString
        try await TestEnvironment.withRooms([
            RoomTestingOptions(roomName: roomName, canPublishData: true),
        ]) { pubRooms in
            let track = try await pubRooms[0].localParticipant.publishDataTrack(name: "pre-join")

            // The subscriber joins *after* the publish; its watcher is the delegate from creation,
            // so it catches the publish delivered during connect (via the JoinResponse). A distinct
            // identity avoids colliding with the publisher in the same room.
            let watcher = DataTrackWatcher(expectedName: "pre-join")
            try await TestEnvironment.withRooms([
                RoomTestingOptions(delegate: watcher, roomName: roomName, identity: "subscriber", canSubscribe: true),
            ]) { _ in
                let remoteTrack = try await watcher.waitForTrack()
                #expect(remoteTrack.info.name == "pre-join")
            }
            _ = track.isPublished // keep `track` alive across the subscriber's join
        }
    }

    // MARK: - Reconnect

    /// A published data track survives a full reconnect: the data track subsystem is session-scoped,
    /// so its manager persists and republishes the track (a recreated manager would lose it). The
    /// subscriber sees the republished track re-announced.
    @Test
    func republishesTrackAfterFullReconnect() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            let track = try await publisher.localParticipant.publishDataTrack(name: "survives-reconnect")
            // Confirm the subscriber sees the initial publication.
            _ = try await subscriber.waitForDataTrack(name: "survives-reconnect")

            // Watch for the re-announcement, then force a full reconnect of the publisher.
            let republishWatcher = DataTrackWatcher(expectedName: "survives-reconnect")
            subscriber.delegates.add(delegate: republishWatcher)
            try await publisher.startReconnect(reason: .debug, nextReconnectMode: .full)

            // The session-scoped manager republishes the track; the subscriber sees it again.
            let republished = try await republishWatcher.waitForTrack()
            #expect(republished.info.name == "survives-reconnect")
            _ = track.isPublished // keep `track` alive across the reconnect (dropping it unpublishes)
        }
    }

    // TODO: add a quick-reconnect (resume) test covering the SyncState.publishDataTracks path.
    // A naive version (subscribe, quick-reconnect the publisher, expect frames on the same stream)
    // is flaky: startReconnect can escalate quick → full, which republishes with a new SID and
    // breaks the existing subscription. Needs a way to pin the reconnect to resume-only (or assert
    // the publication survived without depending on the same SID).

    // MARK: - Concurrency

    /// A multi-track concurrent-push stress scenario.
    struct PushScenario: CustomTestStringConvertible {
        let name: String
        let trackCount: Int
        let framesPerTrack: Int
        let payloadSize: Int
        var testDescription: String { name }

        /// Many small frames across several tracks.
        static let manySmall = PushScenario(name: "manySmall", trackCount: 8, framesPerTrack: 32, payloadSize: 8)
        /// Fewer large multi-packet frames across several tracks.
        static let largeFrames = PushScenario(name: "largeFrames", trackCount: 4, framesPerTrack: 8, payloadSize: 64 * 1024)
    }

    /// A received frame: the stream it arrived on, plus its tagged (track, sequence) header.
    struct ReceivedFrame {
        let stream: Int
        let track: UInt32
        let seq: UInt32
    }

    /// Builds a frame payload tagged with (trackIndex, sequence), padded to `size` bytes.
    private static func makePayload(track: Int, seq: Int, size: Int) -> Data {
        var trackIndex32 = UInt32(track)
        var seq32 = UInt32(seq)
        var data = Data(bytes: &trackIndex32, count: 4)
        data.append(Data(bytes: &seq32, count: 4))
        if size > 8 { data.append(Data(count: size - 8)) }
        return data
    }

    /// Reads the tagged (track, sequence) header from a payload received on `stream`.
    private static func parseFrame(_ payload: Data, stream: Int) -> ReceivedFrame {
        let track = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let seq = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        return ReceivedFrame(stream: stream, track: track, seq: seq)
    }

    /// Publishes several tracks, then pushes every frame on every track at once. Exercises the
    /// Rust manager's per-track send queues and the bridge's packet dispatch under contention.
    /// Each frame is tagged with (trackIndex, sequence); the unreliable channel may drop frames,
    /// but whatever arrives must reach the right track with no duplicates or corruption.
    @Test(arguments: [PushScenario.manySmall, .largeFrames])
    func concurrentPush(_ scenario: PushScenario) async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let framesPerTrack = scenario.framesPerTrack

            // Publish each track and subscribe to it on the remote side.
            var locals: [LocalDataTrack] = []
            var streams: [DataTrackStream] = []
            for i in 0 ..< scenario.trackCount {
                let watcher = DataTrackWatcher(expectedName: "multi-\(i)")
                rooms[1].delegates.add(delegate: watcher)
                try await locals.append(rooms[0].localParticipant.publishDataTrack(name: "multi-\(i)"))
                try await streams.append(watcher.waitForTrack().subscribe())
            }

            // All received frames (flat), drained concurrently with the burst.
            let received = StateSync<[ReceivedFrame]>([])
            var consumers: [Task<Void, Never>] = []
            for (idx, stream) in streams.enumerated() {
                consumers.append(Task {
                    for await frame in stream.values {
                        guard frame.payload.count >= 8 else { continue }
                        let parsed = Self.parseFrame(frame.payload, stream: idx)
                        received.mutate { $0.append(parsed) }
                    }
                })
            }

            // Push every frame on every track concurrently.
            await withTaskGroup(of: Void.self) { group in
                for (trackIndex, track) in locals.enumerated() {
                    for seq in 0 ..< framesPerTrack {
                        let payload = Self.makePayload(track: trackIndex, seq: seq, size: scenario.payloadSize)
                        // try? — a full send queue under the burst is expected, not a failure.
                        group.addTask { try? track.tryPush(frame: DataTrackFrame(payload: payload)) }
                    }
                }
                await group.waitForAll()
            }

            // Let in-flight frames settle, then stop consuming.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            for consumer in consumers {
                consumer.cancel()
            }

            let all = received.copy()
            #expect(!all.isEmpty, "Expected some frames to arrive")
            for streamIndex in 0 ..< scenario.trackCount {
                let frames = all.filter { $0.stream == streamIndex }
                let routedCorrectly = frames.allSatisfy { $0.track == UInt32(streamIndex) }
                let seqs = frames.map(\.seq)
                let noDuplicates = Set(seqs).count == seqs.count
                let inRange = seqs.allSatisfy { $0 < UInt32(framesPerTrack) }
                #expect(routedCorrectly, "Stream \(streamIndex) received a frame from another track")
                #expect(noDuplicates, "Stream \(streamIndex) received a duplicate frame")
                #expect(inRange, "Stream \(streamIndex) received a corrupted sequence")
            }
        }
    }
}
