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

    // MARK: - Subscribe Buffer

    /// Zero is not a valid buffer size and is clamped to one rather than rejected.
    @Test
    func subscribeClampsZeroBufferSize() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "clamped") { fixture in
            let stream = try await fixture.remoteTrack.subscribe(bufferSize: 0)

            let payload = Data([0x2A])
            try fixture.track.tryPush(frame: DataTrackFrame(payload: payload))
            #expect(await stream.next(within: 15)?.payload == payload)
        }
    }

    /// A full receive buffer drops the oldest frames, so a slow reader sees recent data rather
    /// than a stale backlog.
    @Test
    func subscribeDropsOldestAtCapacity() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "drop-oldest") { fixture in
            let stream = try await fixture.remoteTrack.subscribe(bufferSize: 1)

            // Paced so the frames reach the subscriber rather than saturating the send queue.
            for index in 0 ..< UInt8(32) {
                try fixture.track.tryPush(frame: DataTrackFrame(payload: Data([index])))
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            // Let the last frames arrive before reading, so the buffer has to evict.
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let first = try #require(await stream.next(within: 15)?.payload.first)
            #expect(first > 0, "A capacity-one buffer should have dropped the earliest frames")
        }
    }

    // MARK: - Pipeline Options

    /// `maxPartialFrames` can be set before and after subscribing, and a multi-packet frame
    /// still reassembles. Zero is clamped to one rather than rejected.
    @Test
    func setPipelineOptionsReassemblesMultiPacketFrames() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "partials") { fixture in
            fixture.remoteTrack.setPipelineOptions(maxPartialFrames: 4)
            let stream = try await fixture.remoteTrack.subscribe()
            fixture.remoteTrack.setPipelineOptions(maxPartialFrames: 0)

            // Spans several packets, so the depacketizer has to reassemble it. Delivery is lossy
            // and losing one packet loses the whole frame, so retry rather than assert on one push.
            let payload = Data(repeating: 0xFA, count: 32000)
            var received: Data?
            for _ in 0 ..< 3 where received == nil {
                try fixture.track.tryPush(frame: DataTrackFrame(payload: payload))
                received = await stream.next(within: 15)?.payload
            }
            #expect(received == payload)
        }
    }
}
