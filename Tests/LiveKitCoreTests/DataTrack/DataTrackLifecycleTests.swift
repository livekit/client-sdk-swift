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

/// Data track lifecycle: join-time announcements, publication lifetime, and reconnects.
@Suite(.serialized, .tags(.dataTrack, .e2e), TestLimits.e2e)
struct DataTrackLifecycleTests {
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

    /// A published data track survives the publisher's full reconnect: the session-scoped manager
    /// republishes it under a new SID, and the subscriber converges on exactly one live track under
    /// the same name.
    ///
    /// What survives is the *publication*, not any object identity. Depending on whether the SFU
    /// signals the publisher's brief departure, the subscriber may keep its ``RemoteDataTrack`` and
    /// have the SID reassigned in place, or may see the old one unpublished and a new one
    /// published; and the participant object may or may not be recreated independently of that.
    /// Two earlier versions of this test pinned one of those combinations — first the carried-over
    /// track, then the track-follows-participant pairing — and each went red on a slower runner
    /// when a different one happened. So it asserts only what holds in all of them.
    @Test
    func trackSurvivesPublisherFullReconnect() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            let track = try await publisher.localParticipant.publishDataTrack(name: "survives-reconnect")
            // Confirm the subscriber sees the initial publication.
            let remoteTrack = try await subscriber.waitForDataTrack(name: "survives-reconnect")
            let originalSid = remoteTrack.info.sid

            try await publisher.startReconnect(reason: .debug, nextReconnectMode: .full)

            // Read through the participant, never through the captured track: when the track is
            // replaced rather than reassigned, the captured one is orphaned and its SID never
            // rotates.
            try await poll(timeout: 15, for: "the track to be republished under a new SID") {
                guard let participant = subscriber.remoteParticipants.values.first,
                      let republished = participant.dataTracks["survives-reconnect"] else { return false }
                return republished.info.sid != originalSid
            }

            let participant = try #require(subscriber.remoteParticipants.values.first)
            let republished = try #require(participant.dataTracks["survives-reconnect"])
            #expect(republished.info.sid != originalSid)
            #expect(republished.info.name == "survives-reconnect")
            #expect(participant.dataTracks.count == 1, "The old publication must not linger alongside the new one")

            // Deliberately no assertion pairing the republish with an unpublish for `originalSid`.
            // Where the SID is reassigned in place, `remoteTrackUnpublished` — which matches by
            // `info.sid` — finds nothing to match once the rotation has landed, and where the
            // participant was dropped the app already saw it disconnect. Requiring the pair went
            // red three times for three different reasons.
            _ = track.isPublished // keep the publication alive across the reconnect (dropping it unpublishes)
        }
    }

    /// A publish issued while a full reconnect is in flight waits for the new publisher channel
    /// (the open-gate is re-armed on teardown) instead of proceeding against the dead transport.
    @Test
    func publishDuringFullReconnect() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            // startReconnect only returns once the reconnect completes, so run it concurrently
            // and catch the teardown window: transports discarded, replacements not yet up.
            let reconnect = Task { try await publisher.startReconnect(reason: .debug, nextReconnectMode: .full) }
            let deadline = Date().addingTimeInterval(10)
            while publisher._state.transport != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            #expect(publisher._state.transport == nil, "Never observed the reconnect teardown window")

            // The publish must wait for the reconnected channel instead of failing on the dead one.
            //
            // Retried on `.disconnected`, because a publication still *pending* when the reconnect
            // republishes is failed outright by the Rust manager — `on_republish_tracks` in
            // livekit-datatrack answers `Descriptor::Pending` with `PublishError::Disconnected`
            // under a `// TODO: support republish for pending publications`. Whether this publish
            // lands before that runs is a race the SFU's response time decides, and a loaded
            // sanitizer leg loses it. What the test is for — that the publish waits for the
            // rebuilt channel rather than failing on the dead one — still holds, and a regression
            // there fails every attempt.
            let track = try await Task.retrying(totalAttempts: 3, retryDelay: 1) { _, _ in
                try await publisher.localParticipant.publishDataTrack(name: "during-reconnect")
            }.value
            #expect(track.isPublished)
            try await reconnect.value

            _ = try await subscriber.waitForDataTrack(name: "during-reconnect")
            _ = track.isPublished // keep the publication alive until the subscriber sees it
        }
    }

    /// Frames keep flowing across a quick reconnect: `SyncState.publishDataTracks` preserves the
    /// publication and the resumed transports keep the subscription, so the same stream delivers.
    @Test
    func dataTrackSurvivesQuickReconnect() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            let watcher = DataTrackWatcher(expectedName: "sync-state")
            subscriber.delegates.add(delegate: watcher)
            let track = try await publisher.localParticipant.publishDataTrack(name: "sync-state")
            let stream = try await watcher.waitForTrack().subscribe()

            // Quick reconnect (resume). nextReconnectMode: .quick keeps the first attempt on the
            // resume path, which sends SyncState (incl. publishDataTracks) and preserves transports.
            try await publisher.startReconnect(reason: .debug, nextReconnectMode: .quick)

            // Push in the background; assert at least one post-reconnect frame arrives (bounded, so
            // a broken publication fails cleanly instead of hanging).
            let payload = Data("after-quick-reconnect".utf8)
            let pusher = Task {
                while !Task.isCancelled {
                    try? track.tryPush(frame: .now(payload: payload))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer { pusher.cancel() }

            let received = await stream.reader().collect(1) { $0.payload == payload }
            #expect(!received.isEmpty, "Frames should keep flowing after a quick reconnect")
        }
    }

    /// Remote data tracks survive the local client's own full reconnect: cleanup discards the
    /// participant objects (firing unpublish), then the preserved subsystem re-attaches its live
    /// tracks to the recreated participants (re-firing publish) and re-asserts the subscription.
    /// With E2EE on (the `withRooms` default), delivery also proves the data cryptor survives
    /// the teardown.
    @Test
    func remoteTracksSurviveLocalFullReconnect() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            let watcher = DataTrackWatcher(expectedName: "local-full-reconnect")
            subscriber.delegates.add(delegate: watcher)
            let track = try await publisher.localParticipant.publishDataTrack(name: "local-full-reconnect")
            let remoteTrack = try await watcher.waitForTrack()
            let stream = try await remoteTrack.subscribe()

            // Register after the initial publish, so only reconnect-driven events are recorded.
            let recorder = DataTrackDelegateRecorder()
            subscriber.delegates.add(delegate: recorder)

            try await subscriber.startReconnect(reason: .debug, nextReconnectMode: .full)

            // The surviving track is re-attached to the recreated participant and re-announced.
            #expect(try await recorder.waitFor(.roomRemotePublish) == remoteTrack.info.sid)
            let participant = try #require(subscriber.remoteParticipants.values.first)
            #expect(participant.dataTracks[remoteTrack.info.name] === remoteTrack)

            // The track was never unpublished — the reconnect recreates participants, but the
            // subsystem carries its tracks over, so no unpublish should be reported.
            #expect(!recorder.received(.roomRemoteUnpublish))

            // Frames keep flowing on the existing stream once the subscription is re-established.
            let payload = Data("after-full-reconnect".utf8)
            let pusher = Task {
                while !Task.isCancelled {
                    try? track.tryPush(frame: .now(payload: payload))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer { pusher.cancel() }

            let received = await stream.reader().collect(1) { $0.payload == payload }
            #expect(!received.isEmpty, "Frames should keep flowing after the local client's full reconnect")
        }
    }

    // MARK: - Room Move

    /// A cloud migration lands the client in a new room: the old room's publications are gone, and
    /// the participant teardown that precedes the move has already reported them. The coordinator
    /// must forget them without reporting a second time. Driven through the coordinator — a real
    /// move needs a cloud SFU.
    @Test
    func roomMovedDropsPreviousRoomTracksSilently() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "moved") { fixture in
            let publisherIdentity = try #require(fixture.publisher.localParticipant.identity)
            let subscriberIdentity = try #require(fixture.subscriber.localParticipant.identity)
            let participant = try #require(fixture.subscriber.remoteParticipants[publisherIdentity])
            #expect(participant.dataTracks["moved"] != nil)

            let recorder = DataTrackDelegateRecorder()
            fixture.subscriber.delegates.add(delegate: recorder)

            // Stands in for the move's participant teardown, which reports the unpublish itself
            // and is why the coordinator must not report it again. The publisher moves with us, so
            // a participant with the same identity is back by the time the coordinator is told.
            participant.detachDataTracks()

            let movedParticipants = [Livekit_ParticipantInfo.with {
                $0.identity = publisherIdentity.stringValue
            }]
            fixture.subscriber.dataTracks?.handleRoomMoved(movedParticipants, localIdentity: subscriberIdentity.stringValue)

            try await Task.sleep(nanoseconds: 500_000_000)
            #expect(!recorder.received(.roomRemoteUnpublish),
                    "The move reported an unpublish the participant teardown had already reported")
            #expect(participant.dataTracks.isEmpty)
        }
    }
}
