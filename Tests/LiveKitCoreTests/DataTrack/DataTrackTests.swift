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
import LiveKitUniFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.dataTrack, .e2e))
struct DataTrackTests {
    // MARK: - Publish and Receive

    @Test
    func publishAndReceive() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisherRoom = rooms[0]
            let subscriberRoom = rooms[1]

            // Start watching before publishing to avoid race condition
            let watcher = DataTrackWatcher(expectedName: "test")
            subscriberRoom.dataTrackDelegates.add(delegate: watcher)

            let track = try await publisherRoom.localParticipant.publishDataTrack(name: "test")
            #expect(track.isPublished())

            let remoteTrack = try await watcher.waitForTrack()
            #expect(remoteTrack.info().name == "test")

            let stream = try await remoteTrack.subscribe()

            let payload = Data(repeating: 0xAB, count: 1024)
            let frameCount = 10
            for _ in 0 ..< frameCount {
                try track.tryPush(frame: .now(payload: payload))
            }

            var received = 0
            for await frame in stream.values {
                #expect(frame.payload == payload)
                received += 1
                if received >= frameCount - 1 { break }
            }
            #expect(received >= frameCount - 1, "Expected at least \(frameCount - 1) frames, got \(received)")
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
            #expect(first.isPublished())
            do {
                _ = try await room.localParticipant.publishDataTrack(name: "dup")
                Issue.record("Expected duplicate name error")
            } catch {
                // Any error is acceptable — DuplicateName or similar
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
            do {
                _ = try await room.localParticipant.publishDataTrack(name: "unauth")
                Issue.record("Expected PublishError.NotAllowed")
            } catch is PublishError {
                // Expected
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
            #expect(track.isPublished())

            track.unpublish()
            await track.waitForUnpublish()
            #expect(!track.isPublished())
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
            subscriberRoom.dataTrackDelegates.add(delegate: watcher)

            let track = try await publisherRoom.localParticipant.publishDataTrack(name: "ts-test")
            let remoteTrack = try await watcher.waitForTrack()
            let stream = try await remoteTrack.subscribe()

            let payload = Data([1, 2, 3])
            try track.tryPush(frame: .now(payload: payload))

            guard let frame = await stream.next() else {
                Issue.record("Expected a frame")
                return
            }

            #expect(frame.userTimestamp != nil)
            if let latency = frame.latency {
                #expect(latency < 5.0, "Latency should be under 5 seconds, was \(latency)")
            }
        }
    }

    // MARK: - Large Frames (Multi-Packet)

    @Test
    func publishLargeFrames() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisherRoom = rooms[0]
            let subscriberRoom = rooms[1]

            let watcher = DataTrackWatcher(expectedName: "large")
            subscriberRoom.dataTrackDelegates.add(delegate: watcher)

            let track = try await publisherRoom.localParticipant.publishDataTrack(name: "large")
            let remoteTrack = try await watcher.waitForTrack()
            let stream = try await remoteTrack.subscribe()

            // 196KB payload — requires DTP packetization across multiple packets
            let payload = Data((0 ..< 196 * 1024).map { UInt8($0 % 256) })
            let frameCount = 3
            for _ in 0 ..< frameCount {
                try track.tryPush(frame: DataTrackFrame(payload: payload, userTimestamp: nil))
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms between large frames
            }

            var received = 0
            for await frame in stream.values {
                #expect(frame.payload == payload, "Payload mismatch on frame \(received)")
                received += 1
                if received >= frameCount { break }
            }
            #expect(received >= frameCount)
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
            subscriberRoom.dataTrackDelegates.add(delegate: watcher)

            let track = try await publisherRoom.localParticipant.publishDataTrack(name: "resub")
            let remoteTrack = try await watcher.waitForTrack()

            let payload = Data([0xDE, 0xAD])

            // First subscription
            do {
                let stream = try await remoteTrack.subscribe()
                try track.tryPush(frame: DataTrackFrame(payload: payload, userTimestamp: nil))

                guard let frame = await stream.next() else {
                    Issue.record("No frame on first subscription")
                    return
                }
                #expect(frame.payload == payload)
            }
            // Stream dropped — unsubscribes

            // Small delay to let unsubscribe propagate
            try await Task.sleep(nanoseconds: 500_000_000)

            // Second subscription
            do {
                let stream = try await remoteTrack.subscribe()
                try track.tryPush(frame: DataTrackFrame(payload: payload, userTimestamp: nil))

                guard let frame = await stream.next() else {
                    Issue.record("No frame on second subscription")
                    return
                }
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
            let count = 64 // Conservative vs Rust's 256 — faster CI

            var tracks: [LocalDataTrack] = []
            for i in 0 ..< count {
                let track = try await room.localParticipant.publishDataTrack(name: "track-\(i)")
                tracks.append(track)
            }

            #expect(tracks.count == count)
            for (i, track) in tracks.enumerated() {
                #expect(track.info().name == "track-\(i)")
                #expect(track.isPublished())
            }
        }
    }
}
