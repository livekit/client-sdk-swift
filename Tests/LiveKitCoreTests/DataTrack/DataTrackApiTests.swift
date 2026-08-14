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
import LiveKitTestSupport
import Testing

/// Semantics of the publication handle and the subscribe/send conveniences.
@Suite(.serialized, .tags(.dataTrack, .e2e))
struct DataTrackApiTests {
    // MARK: - Publication Lifetime

    /// The handle *is* the publication: dropping the last reference unpublishes it.
    @Test
    func releasingHandleUnpublishes() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "raii")
            rooms[1].delegates.add(delegate: watcher)

            // In a function, so the handle is provably released when it returns.
            func publishAndDrop() async throws -> DataTrack.Sid {
                let track = try await rooms[0].localParticipant.publishDataTrack(name: "raii")
                let remoteTrack = try await watcher.waitForTrack()
                #expect(track.isPublished)
                return remoteTrack.info.sid
            }

            let sid = try await publishAndDrop()
            #expect(try await watcher.waitForUnpublish() == sid)
        }
    }

    @Test
    func withDataTrackScopesPublication() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "scoped")
            rooms[1].delegates.add(delegate: watcher)

            let sid = try await rooms[0].localParticipant.withDataTrack(name: "scoped") { track in
                let remoteTrack = try await watcher.waitForTrack()
                #expect(track.isPublished)
                return remoteTrack.info.sid
            }

            #expect(try await watcher.waitForUnpublish() == sid)
        }
    }

    /// Cancelling the surrounding task unpublishes too — the reason `withDataTrack` installs a
    /// cancellation handler rather than relying on `defer` alone.
    @Test
    func withDataTrackUnpublishesOnCancellation() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "cancelled")
            rooms[1].delegates.add(delegate: watcher)

            let (bodyStarted, bodyStartedContinuation) = AsyncStream.makeStream(of: Void.self)
            let task = Task {
                try await rooms[0].localParticipant.withDataTrack(name: "cancelled") { _ in
                    bodyStartedContinuation.finish()
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
            defer { task.cancel() }

            for await _ in bodyStarted {}
            let remoteTrack = try await watcher.waitForTrack()

            task.cancel()
            #expect(try await watcher.waitForUnpublish() == remoteTrack.info.sid)
        }
    }

    // MARK: - Push Errors

    @Test
    func pushAfterUnpublishThrows() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let track = try await rooms[0].localParticipant.publishDataTrack(name: "unpublished")
            track.unpublish()
            await track.waitForUnpublish()

            let error = await #expect(throws: DataTrackPushFrameError.self) {
                try track.tryPush(frame: DataTrackFrame(payload: Data([0x01])))
            }
            guard case .trackUnpublished = try #require(error) else {
                Issue.record("Expected trackUnpublished, got \(String(describing: error))")
                return
            }
        }
    }

    // MARK: - Backpressure

    /// `.throw` surfaces a saturated queue instead of dropping, and hands the rejected frame back.
    @Test
    func sendContentsOfThrowsOnQueueFull() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let track = try await rooms[0].localParticipant.publishDataTrack(name: "queue-full")

            // A burst far larger than the pipeline queue, pushed as fast as the sequence yields.
            let payload = Data(repeating: 0xAB, count: 128 * 1024)
            let (source, continuation) = AsyncStream.makeStream(of: DataTrackFrame.self)
            for _ in 0 ..< 200 {
                continuation.yield(DataTrackFrame(payload: payload))
            }
            continuation.finish()

            let error = await #expect(throws: DataTrackPushFrameError.self) {
                try await track.send(contentsOf: source, onQueueFull: .throw)
            }
            guard case let .queueFull(_, frame) = try #require(error) else {
                Issue.record("Expected a queueFull error, got \(String(describing: error))")
                return
            }
            #expect(frame.payload == payload, "The rejected frame should be handed back intact")
        }
    }

    // MARK: - Subscribe Buffer

    /// Zero is not a valid buffer size and is clamped to one rather than rejected.
    @Test
    func subscribeClampsZeroBufferSize() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "clamped")
            rooms[1].delegates.add(delegate: watcher)

            let track = try await rooms[0].localParticipant.publishDataTrack(name: "clamped")
            let remoteTrack = try await watcher.waitForTrack()
            let stream = try await remoteTrack.subscribe(bufferSize: 0)

            let payload = Data([0x2A])
            try track.tryPush(frame: DataTrackFrame(payload: payload))
            #expect(await stream.next()?.payload == payload)
        }
    }

    /// A full receive buffer drops the oldest frames, so a slow reader sees recent data rather
    /// than a stale backlog.
    @Test
    func subscribeDropsOldestAtCapacity() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "drop-oldest")
            rooms[1].delegates.add(delegate: watcher)

            let track = try await rooms[0].localParticipant.publishDataTrack(name: "drop-oldest")
            let remoteTrack = try await watcher.waitForTrack()
            let stream = try await remoteTrack.subscribe(bufferSize: 1)

            // Paced so the frames reach the subscriber rather than saturating the send queue.
            for index in 0 ..< UInt8(32) {
                try track.tryPush(frame: DataTrackFrame(payload: Data([index])))
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            // Let the last frames arrive before reading, so the buffer has to evict.
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let first = try #require(await stream.next()?.payload.first)
            #expect(first > 0, "A capacity-one buffer should have dropped the earliest frames")
        }
    }
}
