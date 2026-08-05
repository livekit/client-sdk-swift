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
@Suite(.serialized, .timeLimit(.minutes(5)), .tags(.dataTrack, .e2e))
struct DataTrackLifecycleTests {
    /// A track published before a participant joins surfaces via the JoinResponse.
    @Test
    func receivesTrackPublishedBeforeJoin() async throws {
        let roomName = UUID().uuidString
        try await TestEnvironment.withRooms([
            RoomTestingOptions(roomName: roomName, canPublishData: true),
        ]) { pubRooms in
            _ = try await pubRooms[0].localParticipant.publishDataTrack(name: "pre-join")

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
        }
    }

    // MARK: - Publication Lifetime

    /// The SDK retains the publication, so dropping the returned handle does not unpublish it
    /// (matching JS; the raw Rust handle unpublishes on drop).
    @Test
    func retainsPublicationWhenHandleDropped() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let subscriber = rooms[1]
            let watcher = DataTrackWatcher(expectedName: "retained")
            subscriber.delegates.add(delegate: watcher)

            // Publish and immediately discard the handle.
            _ = try await rooms[0].localParticipant.publishDataTrack(name: "retained")

            let remoteTrack = try await watcher.waitForTrack()
            #expect(remoteTrack.info.name == "retained")
            // Still published a beat later — the dropped handle did not tear it down.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            #expect(remoteTrack.isPublished)
        }
    }

    // MARK: - Reconnect

    /// A published data track survives the publisher's full reconnect: the session-scoped manager
    /// republishes it under a new SID, and the subscriber's existing ``RemoteDataTrack`` carries
    /// over — its SID is reassigned in place.
    @Test
    func trackSurvivesPublisherFullReconnect() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            _ = try await publisher.localParticipant.publishDataTrack(name: "survives-reconnect")
            // Confirm the subscriber sees the initial publication.
            let remoteTrack = try await subscriber.waitForDataTrack(name: "survives-reconnect")
            let originalSid = remoteTrack.info.sid

            // No unpublish/republish events should fire on the subscriber during the reconnect.
            let recorder = DataTrackDelegateRecorder()
            subscriber.delegates.add(delegate: recorder)
            try await publisher.startReconnect(reason: .debug, nextReconnectMode: .full)

            // The existing track object survives; its SID rotates once the track is republished.
            let deadline = Date().addingTimeInterval(15)
            while remoteTrack.info.sid == originalSid, Date() < deadline {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let newSid = remoteTrack.info.sid
            #expect(newSid != originalSid)
            #expect(remoteTrack.info.name == "survives-reconnect")

            // The participant's track map follows the SID reassignment.
            let participant = try #require(subscriber.remoteParticipants.values.first)
            #expect(participant.dataTracks[newSid] === remoteTrack)
            #expect(participant.dataTracks[originalSid] == nil)

            // Depending on whether the SFU signals the publisher's brief departure, the app sees
            // either silent continuity (no events) or a coherent unpublish → publish pair when the
            // participant is dropped and recreated — never a publish without its unpublish.
            if await (try? recorder.waitFor(.roomRemotePublish, timeout: 2)) != nil {
                #expect(try await recorder.waitFor(.roomRemoteUnpublish, timeout: 2) == originalSid)
            }
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

            let received = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await frame in stream.values where frame.payload == payload {
                        return true
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(received, "Frames should keep flowing after a quick reconnect")
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
            #expect(participant.dataTracks[remoteTrack.info.sid] === remoteTrack)

            // Frames keep flowing on the existing stream once the subscription is re-established.
            let payload = Data("after-full-reconnect".utf8)
            let pusher = Task {
                while !Task.isCancelled {
                    try? track.tryPush(frame: .now(payload: payload))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer { pusher.cancel() }

            let received = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await frame in stream.values where frame.payload == payload {
                        return true
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(received, "Frames should keep flowing after the local client's full reconnect")
        }
    }
}
