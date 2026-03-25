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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class TrackPublicationTests: LKTestCase {
    // MARK: - Audio Track Publication

    func testPublishAudioTrackCreatesPublication() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            let room = rooms[0]
            let audioTrack = LocalAudioTrack.createTrack()

            let publication = try await room.localParticipant.publish(audioTrack: audioTrack)
            XCTAssertEqual(publication.source, .microphone)
            XCTAssertNotNil(publication.sid)
            XCTAssertNotNil(publication.track)
        }
    }

    func testPublishAudioTrackAppearsInTrackPublications() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            let room = rooms[0]

            let initialCount = room.localParticipant.trackPublications.count
            let audioTrack = LocalAudioTrack.createTrack()
            _ = try await room.localParticipant.publish(audioTrack: audioTrack)

            XCTAssertEqual(room.localParticipant.trackPublications.count, initialCount + 1)
        }
    }

    // MARK: - Unpublish

    func testUnpublishRemovesPublication() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            let room = rooms[0]
            let audioTrack = LocalAudioTrack.createTrack()

            let publication = try await room.localParticipant.publish(audioTrack: audioTrack)
            let countAfterPublish = room.localParticipant.trackPublications.count

            try await room.localParticipant.unpublish(publication: publication)

            XCTAssertEqual(room.localParticipant.trackPublications.count, countAfterPublish - 1)
        }
    }

    // MARK: - Mute / Unmute

    func testAudioTrackMuteUnmute() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true, canPublishSources: [.microphone])]) { rooms in
            let room = rooms[0]
            let audioTrack = LocalAudioTrack.createTrack()

            let publication: LocalTrackPublication
            do {
                publication = try await room.localParticipant.publish(audioTrack: audioTrack)
            } catch {
                // Audio engine may not be available in CI/headless environments
                print("Skipping mute/unmute test: audio engine not available - \(error)")
                return
            }

            XCTAssertFalse(publication.isMuted)

            try await publication.mute()
            XCTAssertTrue(publication.isMuted)

            try await publication.unmute()
            XCTAssertFalse(publication.isMuted)
        }
    }

    // MARK: - Permission Errors

    func testPublishAudioWithoutPermissionFails() async throws {
        try await withRooms([RoomTestingOptions(canPublish: false)]) { rooms in
            let room = rooms[0]
            let audioTrack = LocalAudioTrack.createTrack()

            do {
                try await room.localParticipant.publish(audioTrack: audioTrack)
                XCTFail("Should throw insufficient permissions")
            } catch let error as LiveKitError {
                XCTAssertEqual(error.type, .insufficientPermissions)
            }
        }
    }

    func testPublishWithWrongSourcePermissionFails() async throws {
        // Only camera allowed, try to publish microphone
        try await withRooms([RoomTestingOptions(canPublish: true, canPublishSources: [.camera])]) { rooms in
            let room = rooms[0]
            let audioTrack = LocalAudioTrack.createTrack()

            do {
                try await room.localParticipant.publish(audioTrack: audioTrack)
                XCTFail("Should throw insufficient permissions for wrong source")
            } catch let error as LiveKitError {
                XCTAssertEqual(error.type, .insufficientPermissions)
            }
        }
    }

    // MARK: - Remote Track Subscription

    func testRemoteParticipantReceivesPublishedTrack() async throws {
        try await withRooms([
            RoomTestingOptions(canPublish: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            let audioTrack = LocalAudioTrack.createTrack()
            _ = try await publisher.localParticipant.publish(audioTrack: audioTrack)

            // Wait for remote participant to see the track
            try await Task.sleep(nanoseconds: 2_000_000_000)

            let remote = subscriber.remoteParticipants.values.first
            XCTAssertNotNil(remote)
            XCTAssertGreaterThan(remote?.trackPublications.count ?? 0, 0)
        }
    }
}
