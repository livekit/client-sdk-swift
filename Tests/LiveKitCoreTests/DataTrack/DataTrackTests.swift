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
            for await frame in stream {
                #expect(frame.payload == payload, "Payload mismatch on frame \(received)")
                received += 1
                if received >= expected { break }
            }
            #expect(received >= expected, "Expected at least \(expected) frames, got \(received)")
        }
    }

    // MARK: - Frame Metadata

    /// Publishing with declared frame metadata (schema + encoding) succeeds and frames flow.
    /// The metadata is sent to the SFU (parity with rust-sdks `DataTrackOptions`), but servers
    /// don't echo it back in track info yet (as of livekit-server 1.13.5), so the round-trip via
    /// ``DataTrackInfo/schema``/``DataTrackInfo/frameEncoding`` isn't asserted here.
    @Test
    func publishWithFrameMetadata() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "typed")
            rooms[1].delegates.add(delegate: watcher)

            let schema = DataTrackSchemaId(name: "my-schema", encoding: .jsonSchema)
            let options = DataTrackPublishOptions(schema: schema, frameEncoding: .json)
            let track = try await rooms[0].localParticipant.publishDataTrack(name: "typed", options: options)
            #expect(track.isPublished)

            let remoteTrack = try await watcher.waitForTrack()
            let stream = try await remoteTrack.subscribe()
            let payload = Data("{}".utf8)
            try track.tryPush(frame: DataTrackFrame(payload: payload))
            let frame = try #require(await stream.next())
            #expect(frame.payload == payload)
        }
    }

    // MARK: - Without E2EE

    /// Data tracks work without E2EE: the publication is not marked encrypted and frames arrive
    /// as sent. Pins the no-encryption path, which every other test here skips — `withRooms`
    /// enables E2EE by default.
    @Test
    func publishAndReceiveWithoutE2ee() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(isE2eeEnabled: false, canPublishData: true),
            RoomTestingOptions(isE2eeEnabled: false, canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "plaintext")
            rooms[1].delegates.add(delegate: watcher)

            let track = try await rooms[0].localParticipant.publishDataTrack(name: "plaintext")
            let remoteTrack = try await watcher.waitForTrack()
            #expect(!remoteTrack.info.usesE2ee)

            let stream = try await remoteTrack.subscribe()
            let payload = Data([0x0B, 0x0E])
            try track.tryPush(frame: DataTrackFrame(payload: payload))
            let frame = try #require(await stream.next())
            #expect(frame.payload == payload)
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
            _ = first.isPublished // keep "dup" published while the duplicate attempt runs
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

    // MARK: - Publish While Disconnected

    /// Publishing on a room that was never connected fails with the data-track error type
    /// (`.disconnected`), matching Rust — not a generic `LiveKitError`.
    @Test
    func publishWhileDisconnectedThrows() async throws {
        await #expect(throws: DataTrackPublishError.self) {
            _ = try await Room().localParticipant.publishDataTrack(name: "nope")
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
            for await frame in stream {
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

            let track = try await rooms[0].localParticipant.publishDataTrack(name: "attached")
            let remoteTrack = try await watcher.waitForTrack()

            let publisherIdentity = try #require(rooms[0].localParticipant.identity)
            let publisher = try #require(rooms[1].remoteParticipants[publisherIdentity])
            #expect(publisher.dataTracks["attached"] === remoteTrack)
            _ = track.isPublished // keep the publication alive through the assertions (dropping it unpublishes)
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

    /// A publisher disconnecting (without an explicit unpublish) should still surface as an
    /// unpublish to the subscriber.
    @Test
    func remoteTrackUnpublishedOnPublisherDisconnect() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            let watcher = DataTrackWatcher(expectedName: "on-disconnect")
            subscriber.delegates.add(delegate: watcher)

            let track = try await publisher.localParticipant.publishDataTrack(name: "on-disconnect")
            let remoteTrack = try await watcher.waitForTrack()

            // Full disconnect, not an explicit unpublish (the handle stays alive so the drop
            // doesn't cause the unpublish itself).
            await publisher.disconnect()
            _ = track.isPublished

            // Bounded wait: cancel the (otherwise unbounded) watcher if nothing arrives in time.
            let unpublishTask = Task { try await watcher.waitForUnpublish() }
            let deadline = Task {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                unpublishTask.cancel()
            }
            let unpublishedSid = try? await unpublishTask.value
            deadline.cancel()

            #expect(unpublishedSid == remoteTrack.info.sid)
        }
    }

    /// Publish/unpublish fires on both subscriber-side delegates (Room + Participant). Local
    /// publications have no delegate events (as in Rust) — the returned handle is the observer.
    @Test
    func publishAndUnpublishNotifyAllDelegates() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            // The subscriber already discovered the publisher (withRooms waits), so its
            // RemoteParticipant exists; register before publishing to catch the publish event.
            let publisherIdentity = try #require(publisher.localParticipant.identity)
            let remotePublisher = try #require(subscriber.remoteParticipants[publisherIdentity])
            let subRecorder = DataTrackDelegateRecorder()
            subscriber.delegates.add(delegate: subRecorder) // room events
            remotePublisher.delegates.add(delegate: subRecorder) // participant events

            let track = try await publisher.localParticipant.publishDataTrack(name: "delegated")

            let remoteSid = try await subRecorder.waitFor(.roomRemotePublish)
            #expect(try await subRecorder.waitFor(.participantRemotePublish) == remoteSid)

            track.unpublish()

            #expect(try await subRecorder.waitFor(.roomRemoteUnpublish) == remoteSid)
            #expect(try await subRecorder.waitFor(.participantRemoteUnpublish) == remoteSid)
        }
    }
}
