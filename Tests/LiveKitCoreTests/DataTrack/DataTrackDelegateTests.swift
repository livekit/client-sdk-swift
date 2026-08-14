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

/// Delegate events for remote data tracks, on both `RoomDelegate` and `ParticipantDelegate`.
@Suite(.serialized, .tags(.dataTrack, .e2e))
struct DataTrackDelegateTests {
    // MARK: - Attached to Remote Participant

    @Test
    func attachedToRemoteParticipant() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "attached") { fixture in
            let publisherIdentity = try #require(fixture.publisher.localParticipant.identity)
            let publisher = try #require(fixture.subscriber.remoteParticipants[publisherIdentity])
            #expect(publisher.dataTracks["attached"] === fixture.remoteTrack)
        }
    }

    // MARK: - Unpublish Delegate

    @Test
    func unpublishNotifiesDelegate() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "to-unpublish") { fixture in
            let watcher = DataTrackWatcher(expectedName: "to-unpublish")
            fixture.subscriber.delegates.add(delegate: watcher)

            let expectedSid = fixture.remoteTrack.info.sid
            fixture.track.unpublish()
            let unpublishedSid = try await watcher.waitForUnpublish()
            #expect(unpublishedSid == expectedSid)
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
