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

/// Publish-time behavior: options and metadata, error cases, and encryption modes.
@Suite(.serialized, .tags(.dataTrack, .e2e))
struct DataTrackPublishTests {
    // MARK: - Frame Metadata

    /// Publishing with declared frame metadata (schema + encoding) succeeds, the metadata is
    /// carried to subscribers through the SFU's track info, and frames flow.
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
            #expect(track.info.schema == schema)
            #expect(track.info.frameEncoding == .json)

            let remoteTrack = try await watcher.waitForTrack()
            // The declared metadata reaches the subscriber through the SFU's track info.
            #expect(remoteTrack.info.schema == schema)
            #expect(remoteTrack.info.frameEncoding == .json)

            let stream = try await remoteTrack.subscribe()
            let payload = Data("{}".utf8)
            try track.tryPush(frame: DataTrackFrame(payload: payload))
            let frame = try #require(await stream.next(within: 15))
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
            let frame = try #require(await stream.next(within: 15))
            #expect(frame.payload == payload)
        }
    }

    /// Whether frames are encrypted is read when the first data track is published, not at
    /// connect, so a toggle issued after connecting still applies.
    @Test
    func encryptionToggleAfterConnectApplies() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let watcher = DataTrackWatcher(expectedName: "toggled")
            rooms[1].delegates.add(delegate: watcher)

            // `withRooms` connects with E2EE enabled; turn it off before publishing anything.
            rooms[0].setE2EEEnabled(false)

            let track = try await rooms[0].localParticipant.publishDataTrack(name: "toggled")
            #expect(!track.info.usesE2ee)
            #expect(try await watcher.waitForTrack().info.usesE2ee == false)
        }
    }

    // MARK: - Schema Definitions

    /// A publisher stores a schema definition and a subscriber resolves it by the ID carried on
    /// the track it describes.
    @Test
    func defineAndGetSchema() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            let watcher = DataTrackWatcher(expectedName: "described")
            subscriber.delegates.add(delegate: watcher)

            let schema = DataTrackSchemaId(name: "reading.v1", encoding: .jsonSchema)
            let definition = #"{"type":"object","properties":{"value":{"type":"number"}}}"#
            try await publisher.localParticipant.defineSchema(schema, definition: definition)

            let options = DataTrackPublishOptions(schema: schema, frameEncoding: .json)
            let track = try await publisher.localParticipant.publishDataTrack(name: "described", options: options)

            let remoteTrack = try await watcher.waitForTrack()
            let declared = try #require(remoteTrack.info.schema)
            #expect(declared == schema)

            let publisherIdentity = try #require(publisher.localParticipant.identity)
            let resolved = try await subscriber.localParticipant.getSchema(declared, publishedBy: publisherIdentity)
            #expect(resolved == definition)
            _ = track.isPublished // keep the publication alive through the assertions
        }
    }

    /// Resolving a schema nobody defined fails rather than hanging.
    @Test
    func getUndefinedSchemaThrows() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisherIdentity = try #require(rooms[0].localParticipant.identity)
            let missing = DataTrackSchemaId(name: "missing.v1", encoding: .protobuf)
            await #expect(throws: LiveKitError.self) {
                _ = try await rooms[1].localParticipant.getSchema(missing, publishedBy: publisherIdentity)
            }
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

    /// Publishing on a disconnected room fails with the data-track error type (`.disconnected`),
    /// matching Rust — not a generic `LiveKitError`.
    @Test
    func publishWhileDisconnectedThrows() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let room = rooms[0]
            await room.disconnect()
            await #expect(throws: DataTrackPublishError.self) {
                _ = try await room.localParticipant.publishDataTrack(name: "nope")
            }
        }
    }
}
